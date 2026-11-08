import AppKit
import BridgeCore
import Charts
import SwiftUI

@MainActor final class CreditHistoryPageModel: ObservableObject {
    typealias Reader = @Sendable (BridgeAPIClient, CreditHistoryQuery) async throws -> CreditHistorySnapshot
    @Published private(set) var snapshot: CreditHistorySnapshot?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private var pending: (BridgeAPIClient, CreditHistoryQuery, UUID)?
    private var token = UUID()
    private var displayed: CreditHistoryQuery?
    private var active = false
    private let reader: Reader
    init(reader: Reader? = nil) { self.reader = reader ?? { client, query in try await client.creditHistory(query: query) } }
    func request(client: BridgeAPIClient?, query: CreditHistoryQuery) {
        if RefreshAcceptance.isReplayMode {
            snapshot = CreditHistoryPreview.snapshot(query: query); displayed = query; error = nil; loading = false
            return
        }
        guard let client else { return }
        active = true
        if displayed != query { snapshot = nil }
        token = UUID(); pending = (client, query, token); loading = true
        if task == nil { task = Task { [weak self] in await self?.drain() } }
    }
    private func drain() async {
        defer {
            task = nil; loading = false
            if active, pending != nil { loading = true; task = Task { [weak self] in await self?.drain() } }
        }
        while let (client, query, requested) = pending {
            pending = nil
            do {
                let value = try await reader(client, query)
                guard !Task.isCancelled else { return }
                if token == requested { snapshot = value; displayed = query; error = nil }
            } catch {
                guard !Task.isCancelled else { return }
                if token == requested { self.error = "Credit history did not refresh. \(error.localizedDescription)" }
            }
        }
    }
    func deactivate() { active = false; token = UUID(); pending = nil; task?.cancel() }
    deinit { task?.cancel() }
}

/// Reported account observations and local price equivalents deliberately have
/// separate cards, filters and provenance. Neither is silently a billing ledger.
struct CreditHistoryView: View {
    @ObservedObject var model: BridgeViewModel
    var localEstimates: CodexCreditEstimates.Result?
    var localUpdating: Bool
    var localScopeLabel: String
    var sessions: [ActivitySession]
    var openSession: (String) -> Void
    @StateObject private var history = CreditHistoryPageModel()
    @State private var window: CreditHistoryQuery.Window = .day
    @State private var selectedScope = "current"
    @State private var dimension = Dimension.model
    @State private var methodology = false
    @State private var rowLimit = 30
    @State private var selectedPoint: String?
    @State private var readingsExpanded = false
    @State private var exportError: String?
    @State private var clock = Date()
    private var renderingNow: Date {
        // The pulse invalidates an aging view, but a newly arrived provider
        // reading can be newer than the last pulse. Validate against wall time.
        _ = clock
        return Date()
    }
    enum Dimension: String, CaseIterable, Identifiable { case model = "Model", project = "Project", session = "Session"; var id: String { rawValue } }

    private var query: CreditHistoryQuery { .init(window: window, scopeID: selectedScope == "current" ? nil : selectedScope) }
    private var requestKey: String {
        [model.runtimeClientID?.uuidString ?? "offline", window.rawValue, selectedScope,
         model.status.quota["codex"]?.fetchedAt?.timeIntervalSince1970.description ?? "none",
         model.status.quota["codex"]?.refreshFailedAt?.timeIntervalSince1970.description ?? "none"].joined(separator: ":")
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CreditBalanceView(estimate: model.status.quota["codex"], account: model.accounts.status(.codex), now: renderingNow,
                    onRefresh: { model.refreshCodexCredits() }, refreshing: model.isRefreshingCodexCredits || !model.isReady,
                    onVisibilityChanged: { model.observeCreditBalance("credits", visible: $0) })
                    .bridgeCard(padding: 16)
                historyControls
                if let snapshot = history.snapshot {
                    historyContent(snapshot)
                } else {
                    HubEmptyState(icon: "clock.arrow.circlepath", title: history.loading ? "Reading saved credit observations…" : "No credit history loaded",
                        message: "History starts with real provider readings. Nothing is filled in for earlier hours.")
                }
                if let error = history.error { Text(error).font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning) }
                if let exportError { Text(exportError).font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning) }
                localBreakdown
                methodSection
            }
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("bridge.page.credits")
        .task(id: requestKey) { history.request(client: model.runtimeClient, query: query) }
        .onDisappear { history.deactivate() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { clock = $0 }
        .acceptanceProbe("page.credits")
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            AcceptanceProbe.handleSafe(note, scope: "credits", state: {
                ["window": window.rawValue, "scope": selectedScope, "dimension": dimension.rawValue,
                 "methodology": String(methodology), "selectedPoint": selectedPoint ?? "none"]
            }, exercise: {
                window = .week; dimension = .project; methodology = true
                selectedPoint = history.snapshot?.history.balancePoints.first?.id
                return true
            })
        }
    }

    private var historyControls: some View {
        HStack(spacing: 10) {
            Text("Account balance history").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
            Spacer(minLength: 8)
            Picker("History period", selection: $window) {
                Text("24h").tag(CreditHistoryQuery.Window.day)
                Text("7 days").tag(CreditHistoryQuery.Window.week)
                Text("All").tag(CreditHistoryQuery.Window.all)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
            Button { history.request(client: model.runtimeClient, query: query) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(BridgeIconButtonStyle()).disabled(history.loading).accessibilityLabel("Refresh saved credit history")
            Button { exportHistory() } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(BridgeIconButtonStyle()).disabled(history.snapshot == nil).accessibilityLabel("Export private credit history")
        }
    }

    private func historyContent(_ snapshot: CreditHistorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            scopeControl(snapshot)
            if let warning = snapshot.recordingWarning {
                CalloutBanner(tone: .warning, title: "History needs attention", detail: warning, compact: true)
            }
            if !snapshot.history.completeness.integrityVerified {
                CalloutBanner(tone: .alert, title: "Saved history did not verify", detail: "Original records are preserved. Rates and forecasts are unavailable until this is investigated.", compact: true)
            }
            if snapshot.history.selectedScope?.kind == .anonymous {
                CalloutBanner(tone: .neutral, title: "Codex didn't say which account this is",
                              detail: "These readings are grouped only while Agent Hub keeps running.",
                              icon: "person.crop.circle.badge.questionmark",
                              note: "Unidentified Codex sign-in: readings stay within this collector run. Restarts are separate unless account identity is reported.",
                              compact: true)
            }
            if snapshot.history.completeness.integrityVerified { summaryCards(snapshot) }
            if !snapshot.history.completeness.integrityVerified {
                Text("Stored history is not being used to draw financial trends. The original file has not been rewritten.")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
            } else if snapshot.history.balancePoints.isEmpty {
                HubEmptyState(icon: "chart.xyaxis.line", title: "Collecting your first readings",
                    message: "Keep a credit view visible to sample every two minutes. A forecast needs at least ten minutes of sufficiently complete readings.")
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) { balanceChart(snapshot.history).frame(minWidth: 330); rateChart(snapshot.history).frame(minWidth: 330) }
                    VStack(spacing: 14) { balanceChart(snapshot.history); rateChart(snapshot.history) }
                }
                observations(snapshot.history)
            }
            if history.loading { Text("Updating saved observations… previous complete data stays visible.").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary) }
        }
    }

    private func scopeControl(_ snapshot: CreditHistorySnapshot) -> some View {
        HStack(spacing: 10) {
            Label(snapshot.isCurrentScope ? "Current readings" : "Older readings · may not be this account",
                  systemImage: snapshot.isCurrentScope ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath")
                .font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textSecondary)
                .help(snapshot.isCurrentScope ? "Readings from the current collector" : "Historical readings · not current account attribution")
            Spacer()
            Picker("Show", selection: $selectedScope) {
                Text("Current readings").tag("current")
                ForEach(snapshot.history.scopes.filter { $0.scope != snapshot.currentScope }) { item in
                    Text(scopeName(item)).tag(item.id)
                }
            }.frame(maxWidth: 340)
        }
    }
    private func scopeName(_ value: CreditHistoryScopeSummary) -> String {
        let name = value.scope.kind == .account ? "Identified account" : value.scope.kind == .imported ? "Imported observations" : "Prior unidentified sign-in"
        return "\(name) · \(value.firstObservedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(value.readingCount) readings"
    }

    /// Plain names lead; how each figure is derived waits behind ⓘ.
    private func summaryCards(_ snapshot: CreditHistorySnapshot) -> some View {
        let report = snapshot.history, forecast = safeForecast(snapshot)
        let decline = report.intervals.filter(\.eligibleForRate).compactMap { $0.estimatedDrawdown.flatMap(Double.init) }.filter(\.isFinite).reduce(0,+)
        return MetricStrip(items: [
            MetricItem(title: "Readings", icon: "checkmark.seal", value: "\(report.records.count)",
                       footnote: "Saved from Codex",
                       info: "Provider observations of your credit balance. Hours without readings are unknown, not zero."),
            MetricItem(title: "Balance used", icon: "arrow.down.right", value: report.rates.isEmpty ? "—" : number(decline),
                       footnote: "Between paired readings",
                       info: "The sum of eligible declines between paired readings. Not an invoice: purchases, grants and resets also change the balance, and increases are left out."),
            MetricItem(title: "Recent pace", icon: "speedometer", value: forecast.estimatedCreditsPerHour.map { "~\(number($0))/h" } ?? "—",
                       footnote: forecast.eligiblePairCount > 0 ? "From \(forecast.eligiblePairCount) intervals" : "Needs more readings",
                       info: "Account-wide estimate from \(forecast.eligiblePairCount) eligible intervals. It covers every device on the account, not just this Mac."),
            MetricItem(title: snapshot.isCurrentScope ? "Runway" : "Runway then", icon: "hourglass",
                       value: forecast.estimatedSecondsRemaining.map { "~" + duration($0) } ?? "—",
                       footnote: forecast.state == .estimated ? (forecast.fasterPaceSecondsRemaining.map { "\(duration($0)) at the faster pace" } ?? "If the pace continues") : reason(forecast.reason),
                       info: (snapshot.isCurrentScope ? "" : "Historical runway scenario, not the current account. ") + (forecast.state == .estimated ? paceRange(forecast) + ". " : "") + "Runway assumes the recent pace continues and no credits are added."),
        ], tint: BridgeTheme.codex)
    }

    private func safeForecast(_ snapshot: CreditHistorySnapshot) -> CreditHistoryForecast {
        CreditForecastSafety.applying(to: snapshot.history.forecast, now: renderingNow, isCurrentScope: snapshot.isCurrentScope,
            integrityVerified: snapshot.history.completeness.integrityVerified, historyReadFailed: history.error != nil,
            providerReadFailed: snapshot.providerRefreshFailedAt != nil || model.status.quota["codex"]?.refreshFailedAt != nil,
            recordingFailed: snapshot.recordingWarning != nil)
    }

    private struct BalancePlot: Identifiable {
        var point: CreditHistoryBalancePoint
        var value: Double
        var segment: Int
        var id: String { point.id }
    }
    private func balancePlots(_ report: CreditHistoryReport) -> [BalancePlot] {
        var segment = 0
        let breaks = Set(report.intervals.filter { !$0.eligibleForRate }.map(\.to))
        return report.balancePoints.suffix(2000).compactMap { point in
            if breaks.contains(point.observedAt) { segment += 1 }
            guard point.isConsistent, let raw = point.reportedBalance, let value = Double(raw), value.isFinite else { segment += 1; return nil }
            return BalancePlot(point: point, value: value, segment: segment)
        }
    }
    private func balanceChart(_ report: CreditHistoryReport) -> some View {
        let points = balancePlots(report)
        let domain = observedDomain(first:points.first?.point.observedAt,last:points.last?.point.observedAt)
        let ticks = HourlyAgentChart.ticks(from:domain.lowerBound,to:domain.upperBound)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Credits left", icon: "creditcard", subtitle: "As Codex reported them",
                info: "Provider-reported credits, not token estimates. The scale starts at zero; pick a reading below for its exact amount. Exact original amounts stay in the saved records. Chart positions use a display approximation. Gaps and inconsistent observations are never bridged. Up to 2,000 recent readings are drawn; exports retain the bounded complete history.") { EmptyView() }
            Chart(points) { point in
                LineMark(x: .value("Read at", point.point.observedAt), y: .value("Credits remaining", point.value), series: .value("Continuous readings", point.segment))
                    .foregroundStyle(BridgeTheme.codex).interpolationMethod(.linear)
                PointMark(x: .value("Read at", point.point.observedAt), y: .value("Credits remaining", point.value))
                    .foregroundStyle(BridgeTheme.codex).symbolSize(selectedPoint == point.id ? 50 : 15)
                    .accessibilityLabel(point.point.observedAt.formatted())
                    .accessibilityValue("\(point.point.reportedBalance ?? "unknown") provider-reported credits")
            }
            .chartYScale(domain: 0...max(1,(points.map(\.value).max() ?? 1)*1.05))
            .chartXScale(domain:domain)
            .chartXAxis { creditTimeAxis(ticks) }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            .frame(height: 190)
        }.frame(maxWidth: .infinity, alignment: .leading).bridgeCard(padding: 16)
    }

    private func rateChart(_ report: CreditHistoryReport) -> some View {
        let rates = Array(report.rates.suffix(2000))
        let domain = observedDomain(first:rates.first?.from,last:rates.last?.to)
        let ticks = HourlyAgentChart.ticks(from:domain.lowerBound,to:domain.upperBound)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Credits used per hour", icon: "flame", subtitle: rates.isEmpty ? "No eligible pairs of readings yet" : "Estimated from drops in the balance",
                info: report.forecast.caveat + " Net balance decrease per hour. Intervals over fifteen minutes, balance increases, missing amounts and conflicting flags are excluded. An increase may be funding or an adjustment; its cause is not reported. Gaps are unknown, not a measured zero rate. A balance decrease is not attributed to a model, project or device.") { EmptyView() }
            Chart(rates) { rate in
                RectangleMark(xStart: .value("From", rate.from), xEnd: .value("To", rate.to),
                              yStart: .value("Estimated credits/hour", 0), yEnd: .value("Estimated credits/hour", rate.estimatedCreditsPerHour))
                    .foregroundStyle(BridgeTheme.codex.opacity(0.7))
                    .accessibilityLabel("\(rate.from.formatted()) to \(rate.to.formatted())")
                    .accessibilityValue("Estimated \(number(rate.estimatedCreditsPerHour)) credits per hour from net balance decrease")
            }
            .chartYScale(domain: 0...max(1,(rates.map(\.estimatedCreditsPerHour).max() ?? 1)*1.15))
            .chartXScale(domain:domain)
            .chartXAxis { creditTimeAxis(ticks) }
            .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) }
            .frame(height: 190)
        }.frame(maxWidth: .infinity, alignment: .leading).bridgeCard(padding: 16)
    }

    private func observedDomain(first:Date?,last:Date?) -> ClosedRange<Date> {
        let end = last ?? renderingNow
        let start = first ?? end.addingTimeInterval(-3600)
        return start < end ? start...end : start.addingTimeInterval(-60)...end.addingTimeInterval(60)
    }

    private func creditTimeAxis(_ ticks:[HourlyAgentChart.Tick]) -> some AxisContent {
        AxisMarks(values:ticks.map(\.date)) { value in
            AxisValueLabel(centered:false,anchor:value.index == 0 ? .topLeading : value.index == ticks.count-1 ? .topTrailing : .top) {
                if let date = value.as(Date.self), let tick = ticks.first(where:{$0.date == date}) {
                    VStack(spacing:1) {
                        Text(tick.timeLabel)
                        Text(tick.dateLabel).foregroundStyle(BridgeTheme.textTertiary)
                    }.font(BridgeFont.micro).fixedSize(horizontal:true,vertical:false)
                }
            }
        }
    }

    private func observations(_ report: CreditHistoryReport) -> some View {
        let increases = report.intervals.filter { $0.kind == .fundingOrAdjustment }.count
        let gaps = report.intervals.filter { $0.kind == .gap }.count
        let recent = Array(report.balancePoints.suffix(12).reversed())
        return VStack(alignment: .leading, spacing: 10) {
            DisclosureGroup(isExpanded: $readingsExpanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(recent) { point in
                        Button { selectedPoint = point.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: point.isConsistent ? "checkmark.circle" : "exclamationmark.circle")
                                    .foregroundStyle(point.isConsistent ? BridgeTheme.codex : BridgeTheme.warning)
                                Text(point.observedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute().second()))
                                Spacer()
                                Text(point.reportedBalance ?? "Not reported").font(BridgeFont.mono).lineLimit(1).minimumScaleFactor(0.7)
                                Text("credits").foregroundStyle(BridgeTheme.textTertiary)
                            }.font(BridgeFont.caption).foregroundStyle(BridgeTheme.textPrimary).padding(8)
                                .background(selectedPoint == point.id ? BridgeTheme.brand.opacity(0.1) : .clear)
                        }.buttonStyle(.plain).accessibilityIdentifier("credit.reading.\(point.id)")
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 8) {
                    SectionTitle(text: "Recent balance readings", icon: "clock.arrow.circlepath")
                    if let latest = recent.first {
                        Text("latest \(latest.reportedBalance ?? "not reported") · \(ActivityFormat.relative(latest.observedAt, now: renderingNow))")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    }
                    Spacer(minLength: 6)
                    if increases > 0 { Tag(text: "\(increases) top-ups or adjustments").help("Balance increases; their cause is not reported") }
                    if gaps > 0 { Tag(text: "\(gaps) sampling gaps").help("Stretches without readings; unknown, not zero") }
                }
            }
            Label("History is kept on this Mac", systemImage: "lock")
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).labelStyle(CompactLabelStyle())
        }.bridgeCard(padding: 16)
    }

    private var localBreakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Local usage at standard credit rates", icon: "square.stack.3d.up", subtitle: localScopeLabel,
                info: "These are estimated credit equivalents from the same canonical token receipts as Models and Projects, not provider charges. The account may include other devices and included allowance. Unknown speed is not guessed from reasoning effort.") { EmptyView() }
            Label("Estimates only, not a breakdown of the balance used above", systemImage: "equal.circle")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).labelStyle(CompactLabelStyle())
            if let estimates = localEstimates {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(estimateNumber(estimates.total.estimatedCredits, partial: estimates.total.isPartial))
                            .font(.system(size: 26, weight: .semibold, design: .rounded)).foregroundStyle(BridgeTheme.codex)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text("standard-rate credits for local Codex usage").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                    }
                    .help("\(estimates.total.coverage.pricedReceiptCount) of \(estimates.total.coverage.receiptCount) Codex receipts have priceable components · rate snapshot \(estimates.catalog.rateAsOf)")
                    Spacer(minLength: 8)
                    Picker("Break down estimates by", selection: $dimension) {
                        ForEach(Dimension.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 230)
                }
                estimateRows(estimates)
            } else {
                Text(localUpdating ? "Preparing local token estimates… saved balance history stays available." : "Local estimates will appear when a native activity snapshot is available.")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            }
        }.bridgeCard(padding: 16)
    }
    private func estimateRows(_ result: CodexCreditEstimates.Result) -> some View {
        let rows = dimension == .model ? result.modelRows : dimension == .project ? result.projectRows : result.sessionRows
        let peak = rows.prefix(rowLimit).compactMap(\.estimatedCredits).filter(\.isFinite).max() ?? 0
        return VStack(spacing: 0) {
            ForEach(Array(rows.prefix(rowLimit))) { row in
                HStack(spacing: 10) {
                    Image(systemName: dimension == .model ? "cpu" : dimension == .project ? "folder" : "rectangle.stack")
                        .foregroundStyle(BridgeTheme.textTertiary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            if let id = row.sessionID {
                                Button(rowTitle(row)) { openSession(id) }.buttonStyle(BridgeLinkButtonStyle()).lineLimit(1)
                            } else { Text(rowTitle(row)).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1) }
                            if let ratio = costPerStepRatio(row, of: result), ratio >= 1.5 {
                                Tag(text: "\(ratio.formatted(.number.precision(.fractionLength(1))))× average cost per step", color: BridgeTheme.brand)
                                    .help("Its share of estimated credits divided by its share of observed steps")
                            }
                        }
                        Text("\(row.coverage.observedModelSteps.formatted()) steps\(stepShare(row, of: result).map { " · \($0) of steps" } ?? "")")
                            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                            .help("\(row.coverage.pricedReceiptCount) of \(row.coverage.receiptCount) receipts have priceable components")
                    }
                    Spacer(minLength: 8)
                    // Relative size at a glance; the figure stays the value.
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.06))
                            if let value = row.estimatedCredits, value.isFinite, value > 0, peak > 0 {
                                Capsule().fill(BridgeTheme.codex.opacity(0.75)).frame(width: max(3, proxy.size.width * CGFloat(value / peak)))
                            }
                        }
                    }
                    .frame(width: 120, height: 6)
                    .accessibilityHidden(true)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(estimateNumber(row.estimatedCredits, partial: row.isPartial)).font(BridgeFont.secondaryMedium.monospacedDigit())
                        if let share = creditShare(row, of: result) {
                            Text("\(share) of credits").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                        }
                    }
                    .frame(minWidth: 90, alignment: .trailing)
                        .foregroundStyle(BridgeTheme.codex)
                        .help(row.reasons.map { "\($0.count): \($0.message)" }.joined(separator: "\n"))
                }.padding(.vertical, 9)
                Divider()
            }
            if rows.count > rowLimit { Button("Show more rows") { rowLimit += 30 }.buttonStyle(BridgeLinkButtonStyle()).padding(.top, 10) }
        }
    }
    /// Shares put an expensive model next to a busy one: a small share of
    /// steps can carry a large share of the estimated credits.
    private func creditShare(_ row: CodexCreditEstimates.Row, of result: CodexCreditEstimates.Result) -> String? {
        guard let value = row.estimatedCredits, let total = result.total.estimatedCredits, value.isFinite, total.isFinite, total > 0 else { return nil }
        return TokenMixStory.percent(value / total)
    }
    private func stepShare(_ row: CodexCreditEstimates.Row, of result: CodexCreditEstimates.Result) -> String? {
        let total = result.total.coverage.observedModelSteps
        guard total > 0 else { return nil }
        return TokenMixStory.percent(Double(row.coverage.observedModelSteps) / Double(total))
    }
    /// Share of credits over share of steps: 1 is average, 2 costs twice as
    /// much per step. Nil when either share is unknown or too small to compare.
    private func costPerStepRatio(_ row: CodexCreditEstimates.Row, of result: CodexCreditEstimates.Result) -> Double? {
        let steps = result.total.coverage.observedModelSteps
        guard let value = row.estimatedCredits, let total = result.total.estimatedCredits, value.isFinite, total.isFinite, total > 0,
              steps > 0, row.coverage.observedModelSteps >= 20 else { return nil }
        let ratio = (value / total) / (Double(row.coverage.observedModelSteps) / Double(steps))
        return ratio.isFinite ? ratio : nil
    }
    private func rowTitle(_ row: CodexCreditEstimates.Row) -> String {
        switch dimension {
        case .model: return row.model.map(ModelNaming.display) ?? "Model not recorded"
        case .project: return row.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Project not recorded"
        case .session:
            if let session = sessions.first(where: { $0.id == row.sessionID }) { return ActivityTitles.display(session.title, provider: session.provider, projectPath: session.projectPath) }
            return row.sessionID ?? "Session not recorded"
        }
    }

    private var methodSection: some View {
        DisclosureGroup(isExpanded: $methodology) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Reported: exact credit balances and flags read from Codex. Derived: signed changes between those balances. Estimated: burn rate, runway, and local standard-rate equivalents.")
                Text("A forecast needs at least three eligible pairs spanning ten minutes, at least 70% sampling coverage, a recent positive capped balance, and no unresolved data conflict. Increases reset the forecast; long gaps break the pace series.")
                Text("Runway assumes future pace continues and no funding or adjustments arrive. The faster/slower range describes observed pace, not a statistical confidence interval. Anonymous collector runs are never silently pooled across restarts.")
                Text("Local estimates use a versioned OpenAI credit-rate snapshot. Cache and reasoning subsets are not added twice. Speed tiers, tools and unobserved usage can change real charges; reasoning effort is not billing speed. API USD/Azure rates are not used.")
                if let snapshot = history.snapshot {
                    Text("History integrity: \(snapshot.history.completeness.integrityVerified ? "verified" : "not verified") · \(snapshot.history.completeness.retainedRecordCount) retained readings · selected stream \(snapshot.history.records.count) readings")
                }
            }.font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
        } label: { Text("How these figures are measured").font(BridgeFont.secondaryMedium) }
        .bridgeCard(padding: 16)
    }
    private func exportHistory() {
        guard let snapshot = history.snapshot else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "agent-hub-credit-history.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try CreditHistoryExport.write(try BridgeJSON.encoder.encode(snapshot), to: url); exportError = nil }
        catch { exportError = "Credit history was not exported: \(error.localizedDescription)" }
    }
    private func number(_ value: Double) -> String { value.isFinite ? value.formatted(.number.precision(.fractionLength(0...2))) : "—" }
    private func estimateNumber(_ value: Double?, partial: Bool) -> String { value.map { (partial ? "≥" : "~") + number($0) } ?? "—" }
    private func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        return seconds > 365*86_400 ? "more than a year" : ActivityFormat.duration(seconds)
    }
    private func paceRange(_ forecast: CreditHistoryForecast) -> String {
        guard let fast = forecast.fasterPaceSecondsRemaining else { return forecast.caveat }
        return "Observed pace range: \(duration(fast)) to \(forecast.slowerPaceSecondsRemaining.map(duration) ?? "open-ended")"
    }
    private func reason(_ key: String) -> String {
        switch key {
        case "need_three_pairs_over_ten_minutes": return "Collecting readings · first forecast after at least 10 minutes"
        case "sampling_coverage_below_seventy_percent": return "Too many gaps for a useful forecast"
        case "no_observed_drawdown_no_runway": return "No balance decrease observed; no depletion date guessed"
        case "latest_reading_stale": return "Refresh the balance for a current forecast"
        case "latest_provider_read_failed", "latest_reading_not_saved", "history_read_failed": return "Latest reading is unavailable; forecast paused"
        case "imported_scope_not_current_account": return "Imported history cannot establish the current account's runway"
        case "need_consistent_positive_capped_balance": return "Needs a balance above zero to forecast"
        default: return "Not enough reliable evidence for a forecast"
        }
    }
}

/// Explicit isolated replay only; this never reaches the private ledger or a
/// provider. The test window is branded as a fixture by the existing harness.
private enum CreditHistoryPreview {
    static func snapshot(query: CreditHistoryQuery) -> CreditHistorySnapshot? {
        let now = Date()
        let scope = CreditHistoryScope.account("synthetic-credit-fixture")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var records: [[String: Any]] = []
        for index in 0..<6 {
            let timestamp = formatter.string(from:now.addingTimeInterval(Double(index-5)*125))
            let row: [String: Any] = ["schemaVersion":"credit-history/1", "sequence":index+1,
                "scope":["kind":scope.kind.rawValue,"id":scope.id], "observedAt":timestamp,
                "reportedBalance":String(1000-index*5),"hasCredits":true,"unlimited":false,
                "source":"live","limitID":"codex","warnings":["synthetic_test_fixture"],
                "recordHash":"synthetic-credit-\(index)"]
            records.append(row)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: records),
              let decoded = try? BridgeJSON.decoder.decode([CreditHistoryRecord].self, from:data) else { return nil }
        let report = CreditHistoryAnalytics.report(records:decoded, now:now, from:query.from(at:now), to:now, scope:scope)
        return try? BridgeJSON.decoder.decode(CreditHistorySnapshot.self, from: JSONSerialization.data(withJSONObject: [
            "schemaVersion":"credit-report/1",
            "history":JSONSerialization.jsonObject(with:BridgeJSON.compactEncoder.encode(report)),
            "currentScope":["kind":scope.kind.rawValue,"id":scope.id]
        ]))
    }
}
