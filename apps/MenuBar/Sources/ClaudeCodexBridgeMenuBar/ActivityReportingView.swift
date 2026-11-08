import AppKit
import BridgeCore
import Charts
import SwiftUI
import UniformTypeIdentifiers

/// Shared presentation rules keep unavailable measurements distinct from zero.
enum ActivityDisplay {
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "Unavailable" }
        guard let value = Int(exactly: seconds.rounded(.down)) else { return "Unavailable" }
        if value >= 86_400 { return "\(value / 86_400)d \((value % 86_400) / 3_600)h" }
        if value >= 3_600 { return "\(value / 3_600)h \((value % 3_600) / 60)m" }
        if value >= 60 { return "\(value / 60)m \(value % 60)s" }
        return "\(value)s"
    }

    static func count(_ number: Int?) -> String { number?.formatted() ?? "Unavailable" }
    static func compact(_ number: Int?) -> String {
        guard let number else { return "Unavailable" }
        return number.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
    static func project(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "Unattributed project" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
    static func state(_ value: String) -> String {
        switch value.lowercased() {
        case "notloaded", "unknown", "not_loaded": return "Live state unavailable"
        case "active", "running", "inprogress", "in_progress": return "Working"
        case "idle": return "Idle in connected runtime"
        case "paused": return "Paused"
        case "waiting", "waitingforapproval", "waiting_for_approval": return "Waiting"
        case "complete", "completed": return "Completed"
        default: return value.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
    static func isWorking(_ value: String) -> Bool {
        ["active", "running", "inprogress", "in_progress"].contains(value.lowercased())
    }
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    static func turns(_ sessions: [ActivitySession], after cutoff: Date? = nil, before end: Date = Date()) -> [ActivityTurn] {
        // Forked histories can replay the same provider turn. Aggregate once.
        ActivityAnalytics.scopedTurns(ActivityMetrics.uniqueTurns(sessions), from: cutoff, to: end)
    }
}

/// Formatting and visual grouping over the shared Core report. No native token
/// pool, model-default list or alternate ownership calculation enters a metric.
enum ActivityReportPresentation {
    static func ownWork(_ sessionID: String, overview: ActivityOverview) -> ActivityAccounting.Report {
        ActivityAccounting.build(overview: overview, sessionIDs: [sessionID], from: nil, to: overview.generatedAt)
    }
    static func models(_ report: ActivityAccounting.Report, sessionID: String? = nil) -> [String] {
        if let sessionID {
            return Array(Set(report.receipts.filter { $0.countsAsModelStep && $0.sessionID == sessionID }.compactMap(\.model))).sorted()
        }
        return Array(Set(report.modelRows.filter { $0.requests > 0 }.compactMap(\.name))).sorted()
    }
    static func efforts(_ report: ActivityAccounting.Report, sessionID: String? = nil) -> [String] {
        if let sessionID {
            return Array(Set(report.receipts.filter { $0.countsAsModelStep && $0.sessionID == sessionID }.compactMap(\.effort))).sorted()
        }
        return Array(Set(report.modelRows.filter { $0.requests > 0 }.flatMap { $0.efforts.map(\.name) })).sorted()
    }
    static func lastActivity(_ report: ActivityAccounting.Report, sessionID: String? = nil) -> Date? {
        let dates = report.receipts.filter { sessionID == nil || $0.sessionID == sessionID }.compactMap(\.timestamp)
            + report.nativeObservations.filter { sessionID == nil || $0.sessionID == sessionID }.compactMap(\.timestamp)
        return dates.filter { date in
            date.timeIntervalSinceReferenceDate.isFinite && date < report.scope.to && (report.scope.from.map { date >= $0 } ?? true)
        }.max()
    }
    /// Index already-owned facts once for lists; metadata updates and copied
    /// parent history must not make a quiet child appear recently active.
    static func lastActivityBySession(_ report: ActivityAccounting.Report) -> [String: Date] {
        var result: [String: Date] = [:]
        func record(_ date: Date?, sessionID: String) {
            guard let date, date.timeIntervalSinceReferenceDate.isFinite, date < report.scope.to,
                  report.scope.from.map({ date >= $0 }) ?? true else { return }
            result[sessionID] = max(result[sessionID] ?? date, date)
        }
        for receipt in report.receipts { record(receipt.timestamp, sessionID: receipt.sessionID) }
        for observation in report.nativeObservations { record(observation.timestamp, sessionID: observation.sessionID) }
        return result
    }
    static func recordedActivityLabel(_ date: Date?, now: Date = Date()) -> String {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite else { return "No dated activity" }
        return "Last recorded activity \(ActivityFormat.relative(date, now: now))"
    }
    static func recordedActivityHelp(_ date: Date?, systemTimeZone: TimeZone = .current) -> String {
        guard let date, date.timeIntervalSinceReferenceDate.isFinite else {
            return "No dated activity is available in this saved history. This does not establish whether the agent is idle."
        }
        return "Last recorded activity: \(exactActivityDate(date, systemTimeZone: systemTimeZone)).\nFrom this agent's own saved evidence; not a live process check."
    }
    static func exactActivityDate(_ date: Date, systemTimeZone: TimeZone = .current) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return "Time unavailable" }
        func formatted(_ timeZone: TimeZone) -> String {
            let style = Date.FormatStyle(date: .abbreviated, time: .standard, timeZone: timeZone).secondFraction(.fractional(3))
            return "\(date.formatted(style)) (\(timeZone.identifier))"
        }
        let reportingTimeZone = ActivityAnalytics.reportingTimeZone
        let reported = formatted(reportingTimeZone)
        return systemTimeZone.identifier == reportingTimeZone.identifier ? reported : "\(reported); system time: \(formatted(systemTimeZone))"
    }
    static func categoryEvidence(_ report: ActivityAccounting.Report) -> [ActivityTurn] {
        report.nativeObservations.filter(\.countersIncludedInWindow).map {
            ActivityTurn(id: $0.id, categories: $0.categories, artifacts: $0.artifacts)
        }
    }
    static func mix(_ report: ActivityAccounting.Report) -> [ActivityAnalytics.Share] {
        ActivityAnalytics.categoryMix(categoryEvidence(report))
    }
    static func tokens(_ report: ActivityAccounting.Report, output: Bool = false) -> String {
        let value = output ? report.totals.outputKnown : report.totals.tokensKnown
        let partial = output ? report.totals.outputIsPartial : report.totals.tokensArePartial
        guard let value else { return "—" }
        return (partial ? "≥" : "") + ActivityFormat.compact(value)
    }
    static func steps(_ report: ActivityAccounting.Report) -> String {
        guard report.isValid, report.scope.asOf != .distantPast else { return "—" }
        if report.totals.observedModelSteps == 0 && report.summary.unmeasuredTurns > 0 { return "—" }
        return (report.totals.modelStepsArePartial ? "≥" : "") + report.totals.observedModelSteps.formatted()
    }
    static func providerGoalCounter(_ goal: ActivityGoal) -> String {
        "Provider goal counter · \(ActivityFormat.compact(goal.tokensUsed)) tokens · \(ActivityFormat.duration(goal.providerTimeSeconds)) reported time"
    }
}

struct InspectorPreparedPresentation {
    var ownWork: ActivityAccounting.Report
    var descendants: [ActivitySession]
    var lastActivityBySession: [String: Date]
}

/// One family projection per accepted snapshot. Only the selected session's
/// own report is retained, alongside compact descendant dates and row order.
/// Runtime redraws and each child row must not normalize native history again.
final class InspectorAccountingCache {
    private var sessionID: String?
    private var revision: UInt64?
    private var generatedAt: Date?
    private var presentation: InspectorPreparedPresentation?
    private(set) var preparationCount = 0
    func value(sessionID: String, overview: ActivityOverview, revision: UInt64) -> ActivityAccounting.Report {
        prepared(sessionID: sessionID, overview: overview, revision: revision).ownWork
    }
    func prepared(sessionID: String, overview: ActivityOverview, revision: UInt64) -> InspectorPreparedPresentation {
        if let presentation, self.sessionID == sessionID, self.revision == revision, generatedAt == overview.generatedAt { return presentation }
        reset()
        let session = overview.sessions.first { $0.id == sessionID }
        let descendants = session.map { ActivityAnalytics.descendants(of: $0, in: overview.sessions) } ?? []
        let familyIDs = Set([sessionID] + descendants.map(\.id))
        let family = ActivityAccounting.build(overview: overview, sessionIDs: familyIDs, from: nil, to: overview.generatedAt)
        let dates = ActivityReportPresentation.lastActivityBySession(family)
        let createdDates = Dictionary(uniqueKeysWithValues: descendants.map { ($0.id, ActivityAccountingPrecision.date($0.createdAt) ?? .distantPast) })
        let ordered = descendants.sorted { lhs, rhs in
            switch (dates[lhs.id], dates[rhs.id]) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let left = createdDates[lhs.id] ?? .distantPast, right = createdDates[rhs.id] ?? .distantPast
                return left == right ? lhs.id < rhs.id : left > right
            }
        }
        let result = InspectorPreparedPresentation(ownWork: family.projected(sessionIDs: [sessionID]),
            descendants: ordered, lastActivityBySession: dates)
        self.sessionID = sessionID; self.revision = revision; generatedAt = overview.generatedAt; presentation = result
        preparationCount += 1
        return result
    }
    func reset() { presentation = nil; sessionID = nil; revision = nil; generatedAt = nil }
}

/// One intentional goal/range projection, not a full-history normalization on
/// every timer/status redraw. A revision catches same-timestamp corrections.
struct GoalPreparedPresentation {
    var report: ActivityAccounting.Report
    var lanes: [ActivityAnalytics.Lane]
    var curve: [ActivityAnalytics.ConcurrencyPoint]
    var descendants: [ActivitySession]
    var assignments: [String: AgentPersonaCatalog.Assignment]
    var lastActivityBySession: [String: Date]
    var modelsBySession: [String: [String]]
    var effortsBySession: [String: [String]]
    var artifacts: [ActivityArtifact]
    var mix: [ActivityAnalytics.Share]
    var load: [ActivityAnalytics.LoadBucket]
    var categoryLegend: [(name: String, count: Int)]
}

final class GoalAccountingCache {
    struct Key: Equatable {
        var sessionID: String
        var revision: UInt64
        var asOf: Date
        var from: Date
        var to: Date
    }
    private var key: Key?
    private var report: ActivityAccounting.Report?
    private var presentation: GoalPreparedPresentation?
    private(set) var preparationCount = 0
    private let assignments: (ActivityOverview) -> [String: AgentPersonaCatalog.Assignment]
    private let build: (ActivityOverview, String, Date, Date) -> ActivityAccounting.Report
    init(assignments: @escaping (ActivityOverview) -> [String: AgentPersonaCatalog.Assignment] = { PersonaDirectory.assignments(for: $0) },
         build: @escaping (ActivityOverview, String, Date, Date) -> ActivityAccounting.Report = { overview, id, from, to in
        let session = overview.sessions.first { $0.id == id }
        let family = session.map { [$0] + ActivityAnalytics.descendants(of: $0, in: overview.sessions) } ?? []
        return ActivityAccounting.build(overview: overview, sessionIDs: Set(family.map(\.id)), from: from, to: to)
    }) { self.assignments = assignments; self.build = build }
    func value(overview: ActivityOverview, sessionID: String, revision: UInt64, from: Date, to: Date) -> ActivityAccounting.Report {
        let incoming = Key(sessionID: sessionID, revision: revision, asOf: overview.generatedAt, from: from, to: to)
        if incoming == key, let report { return report }
        let result = build(overview, sessionID, from, to)
        key = incoming; report = result; presentation = nil
        return result
    }
    func prepared(overview: ActivityOverview, sessionID: String, revision: UInt64, from: Date, to: Date) -> GoalPreparedPresentation {
        let report = value(overview: overview, sessionID: sessionID, revision: revision, from: from, to: to)
        if let presentation { return presentation }
        let session = overview.sessions.first { $0.id == sessionID }
        let descendants = session.map { ActivityAnalytics.descendants(of: $0, in: overview.sessions) } ?? []
        let lanes = session.map { ActivityAnalytics.lanes(for: $0, in: overview.sessions, from: from, to: to) } ?? []
        var lastActivity: [String: Date] = [:]
        var models: [String: Set<String>] = [:]
        var efforts: [String: Set<String>] = [:]
        func recordDate(_ date: Date?, sessionID: String) {
            guard let date, date.timeIntervalSinceReferenceDate.isFinite, date < report.scope.to,
                  report.scope.from.map({ date >= $0 }) ?? true else { return }
            lastActivity[sessionID] = max(lastActivity[sessionID] ?? date, date)
        }
        // Build indexes in one pass, rather than filtering/copying the full
        // receipt array once for every agent and every timer redraw.
        for receipt in report.receipts {
            recordDate(receipt.timestamp, sessionID: receipt.sessionID)
            if receipt.countsAsModelStep {
                if let model = receipt.model { models[receipt.sessionID, default: []].insert(model) }
                if let effort = receipt.effort { efforts[receipt.sessionID, default: []].insert(effort) }
            }
        }
        for item in report.nativeObservations { recordDate(item.timestamp, sessionID: item.sessionID) }
        var categories: [String: Int] = [:]
        for lane in lanes { for segment in lane.segments { categories[segment.category ?? "Tools not recorded", default: 0] += 1 } }
        var legend: [(name: String, count: Int)] = categories.map { pair in (name: pair.key, count: pair.value) }
        legend.sort { lhs, rhs in
            if lhs.count == rhs.count { return lhs.name < rhs.name }
            return lhs.count > rhs.count
        }
        let artifacts = Dictionary(report.artifacts.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.path < $1.path }
        let result = GoalPreparedPresentation(report: report, lanes: lanes,
            curve: ActivityAnalytics.concurrency(lanes, from: from, to: to, buckets: 120), descendants: descendants,
            assignments: assignments(overview), lastActivityBySession: lastActivity,
            modelsBySession: models.mapValues { $0.sorted() }, effortsBySession: efforts.mapValues { $0.sorted() },
            artifacts: artifacts, mix: report.categoryMix,
            load: ActivityAnalytics.load(lanes, from: from, to: to, bucketSeconds: 900), categoryLegend: legend)
        presentation = result; preparationCount += 1
        return result
    }
    func reset() { key = nil; report = nil; presentation = nil }
}

/// Goal stories built off the main thread and kept across page visits. A
/// new snapshot or range is prepared in the background while the last story
/// for that goal stays on screen, so the page never freezes on a refresh.
@MainActor final class GoalPresentationStore: ObservableObject {
    static let shared = GoalPresentationStore()
    struct Entry {
        var key: GoalAccountingCache.Key
        var value: GoalPreparedPresentation
    }
    private struct Box: @unchecked Sendable { let value: GoalPreparedPresentation }
    /// The newest story per goal session.
    @Published private(set) var entries: [String: Entry] = [:]
    private var building: [String: GoalAccountingCache.Key] = [:]
    static let limit = 8

    func entry(for key: GoalAccountingCache.Key) -> Entry? {
        entries[key.sessionID].flatMap { $0.key == key ? $0 : nil }
    }
    func latest(for sessionID: String) -> Entry? { entries[sessionID] }

    func prepare(overview: ActivityOverview, key: GoalAccountingCache.Key) async {
        guard entry(for: key) == nil, building[key.sessionID] != key else { return }
        building[key.sessionID] = key
        let built = await Task.detached(priority: .userInitiated) {
            Box(value: GoalAccountingCache().prepared(overview: overview, sessionID: key.sessionID, revision: key.revision, from: key.from, to: key.to))
        }.value
        if building[key.sessionID] == key { building[key.sessionID] = nil }
        // A newer request for this goal may have finished first.
        if let current = entries[key.sessionID], current.key.revision > key.revision { return }
        entries[key.sessionID] = Entry(key: key, value: built.value)
        while entries.count > Self.limit, let victim = entries.keys.first(where: { $0 != key.sessionID }) { entries.removeValue(forKey: victim) }
    }
}

/// Derived once per accepted snapshot, off the main thread. Wall-clock ticks
/// update recency labels only; they never rebuild the accounting graph.
struct ActivityInsight: Sendable {
    let overview: ActivityOverview
    var now: Date
    let report: ActivityAccounting.Report
    let weekReport: ActivityAccounting.Report
    let todayReport: ActivityAccounting.Report
    let goalReport: ActivityAccounting.Report?
    let daily7: [ActivityAccounting.Point]
    let sessionReports: [String: ActivityAccounting.Report]
    var asOf: Date { overview.generatedAt }

    init(_ overview: ActivityOverview, now: Date = Date()) {
        self.overview = overview
        self.now = now
        let end = overview.generatedAt
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ActivityAnalytics.reportingTimeZone
        let todayStart = calendar.startOfDay(for: end)
        let weekStart = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        report = ActivityAccounting.build(overview: overview, from: nil, to: end)
        weekReport = ActivityAccounting.build(overview: overview, from: weekStart, to: end)
        todayReport = ActivityAccounting.build(overview: overview, from: todayStart, to: end)
        daily7 = weekReport.series(granularity: .day).points
        sessionReports = report.bySession()
        if let pinned = overview.pinnedSession {
            let family = Set(([pinned] + ActivityAnalytics.descendants(of: pinned, in: overview.sessions)).map(\.id))
            goalReport = ActivityAccounting.build(overview: overview, sessionIDs: family,
                from: pinned.goal?.createdAt ?? pinned.createdAt, to: end)
        } else { goalReport = nil }
    }

    func withClock(_ date: Date) -> Self { var value = self; value.now = date; return value }

    var snapshotDayTitle: String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = ActivityAnalytics.reportingTimeZone
        return calendar.isDate(asOf, inSameDayAs: now) ? "Today" : "Snapshot day"
    }

    var pinned: ActivitySession? { overview.pinnedSession }

    var children: [ActivitySession] {
        guard let pinned else { return [] }
        return ActivityAnalytics.descendants(of: pinned, in: overview.sessions)
    }

    func lanes(hours: Double) -> [ActivityAnalytics.Lane] {
        guard let pinned else { return [] }
        return ActivityAnalytics.lanes(for: pinned, in: overview.sessions, from: now.addingTimeInterval(-hours * 3_600), to: now)
    }

    /// Agents with a turn start or end in the last 15 minutes. This is
    /// recent evidence, not a live process check.
    var recentlyActive: [ActivitySession] {
        let recentIDs = Set((report.receipts.compactMap { receipt -> String? in
            ActivityPresentationPolicy.isRecent(receipt.timestamp, now: now) ? receipt.sessionID : nil
        }) + report.nativeObservations.compactMap { item in
            ActivityPresentationPolicy.isRecent(item.timestamp, now: now) ? item.sessionID : nil
        })
        return overview.sessions.filter { recentIDs.contains($0.id) }
    }

}

struct ActivityCompactHeader: View {
    @ObservedObject var model: BridgeViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let insight = model.activityInsight?.withClock(context.date)
            let active = insight?.recentlyActive.count ?? 0
            let loading = insight == nil || insight?.overview.generatedAt == .distantPast
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill((active > 0 ? BridgeTheme.success : BridgeTheme.textTertiary).opacity(0.18)).frame(width: 30, height: 30)
                    Image(systemName: "waveform.path").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(active > 0 ? BridgeTheme.success : BridgeTheme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(loading ? "Reading activity…" : active > 0 ? "\(active) recent \(active == 1 ? "session" : "sessions")" : "No recent sessions").font(BridgeFont.title)
                    Text(insight.map(subtitle) ?? "Preparing saved activity…").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                }
                Spacer()
                if model.isRefreshingActivity { ProgressView().controlSize(.small).help("Updating activity receipts") }
                if let insight, !insight.recentlyActive.isEmpty {
                    let assignments = PersonaDirectory.assignments(for: insight.overview)
                    PortraitStack(items: insight.recentlyActive.sorted { $0.updatedAt > $1.updatedAt }.map {
                        (assignments[$0.id]?.persona, $0.provider, true)
                    }, size: 24, limit: 4)
                    .help(insight.recentlyActive.map(\.title).joined(separator: "\n"))
                } else {
                    HStack(spacing: -5) {
                        AgentAvatar(name: "Claude", size: 16, dimmed: true)
                        AgentAvatar(name: "Codex", size: 16, dimmed: true)
                    }
                    .help(loading ? "No activity snapshot has been collected yet" : "No dated canonical model steps or native events in the last 15 minutes")
                }
            }
            .foregroundStyle(BridgeTheme.textPrimary)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }

    private func subtitle(_ insight: ActivityInsight) -> String {
        let goals = insight.overview.activeGoals.count
        var parts: [String] = []
        if goals > 0 { parts.append("\(goals) open \(goals == 1 ? "goal" : "goals")") }
        if parts.isEmpty { parts.append("in the last 15 minutes") }
        return parts.joined(separator: " · ")
    }
}

struct ActivityHUDView: View {
    @ObservedObject var model: BridgeViewModel
    @ObservedObject private var panel = MenuBarController.shared

    var body: some View {
        // The panel's hosting view outlives each opening. Building the HUD
        // only while it is on screen keeps a closed panel from recomputing
        // highlights and charts on every timer tick and data change.
        if panel.isOpen || ProcessInfo.processInfo.environment["BRIDGE_UI_PREVIEW"] == "1" {
            content
        } else {
            Color.clear.frame(height: 1)
        }
    }

    private var content: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let insight = model.activityInsight?.withClock(context.date)
            VStack(alignment: .leading, spacing: 10) {
                if let error = model.activityError {
                    Text(error).font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                planCard(now: context.date)
                if let insight {
                highlights(insight)
                if let pinned = insight.pinned {
                    goalCard(pinned, insight: insight)
                } else {
                    emptyGoal
                }
                todayGrid(insight)
                workMix(insight)
                recentAgents(insight)
                } else {
                    HydrationComponentPlaceholder(message: "Preparing saved activity…",
                                                  isReading: model.activityError == nil && model.connectionPhase != .unavailable)
                        .acceptanceProbe("loading")
                }
                Button { model.openActivityReports() } label: {
                    HStack { Text("Open \(BridgeBrand.shortName)"); Spacer(); Image(systemName: "arrow.up.right") }
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BridgePrimaryButtonStyle())
                .keyboardShortcut("r", modifiers: [.command, .shift])
                HStack {
                    Text(insight == nil ? "Reading activity…" : "Updated \(ActivityFormat.relative(insight?.asOf, now: context.date))")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                    Spacer()
                    Button { model.refreshActivity() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(BridgeIconButtonStyle()).disabled(model.isRefreshingActivity)
                        .accessibilityLabel("Refresh activity")
                }
            }
        }
        .foregroundStyle(BridgeTheme.textPrimary)
        .acceptanceProbe("panel.hud")
        .onAppear { model.observeActivity("panel", visible: MenuBarController.shared.isPanelVisible || ProcessInfo.processInfo.environment["BRIDGE_UI_PREVIEW"] == "1") }
        .onDisappear { model.observeActivity("panel", visible: false) }
    }

    // MARK: Plan

    private func planCard(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Plans & credits", icon: "gauge.with.dots.needle.67percent")
                Spacer()
                Button { model.refreshPlanUsage() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(BridgeIconButtonStyle(size: 20)).disabled(model.isBusy || !model.isReady)
                    .help("Check plan limits now")
            }
            PlanMeterRow(name: "Claude", agent: .claude, estimate: model.status.quota["claude"], now: now)
            Hairline()
            PlanMeterRow(name: "ChatGPT", agent: .codex, estimate: model.status.quota["codex"], now: now, account: model.accounts.status(.codex),
                onCreditRefresh: { model.refreshCodexCredits() }, creditsRefreshing: model.isRefreshingCodexCredits || !model.isReady,
                onCreditVisibilityChanged: { model.observeCreditBalance("panel", visible: $0) },
                openCreditHistory: { model.openPage(.credits) })
        }
        .bridgeCard(padding: 12)
    }

    // MARK: Highlights

    @ViewBuilder
    private func highlights(_ insight: ActivityInsight) -> some View {
        let quotas = Dictionary(uniqueKeysWithValues: AgentName.allCases.compactMap { agent in model.status.quota[agent.rawValue].map { (agent, $0) } })
        let items = ActivityHighlights.make(.init(sessions: insight.overview.sessions, from: insight.weekReport.scope.from, to: insight.weekReport.scope.to, quotas: quotas,
                                                  account: insight.overview.accountUsage, accounting: insight.weekReport, providerNow: insight.now), limit: 12)
            .filter { ![.planPace, .planLow, .planHealthy].contains($0.kind) }
            .prefix(2)
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionTitle(text: "What stands out · 7 days", icon: "sparkles")
                    Spacer()
                }
                ForEach(Array(items)) { item in
                    HighlightCard(highlight: item, compact: true,
                                  action: item.sessionID.map { id in { model.openActivityReports(sessionID: id) } })
                }
            }
        }
    }

    // MARK: Goal

    private func goalCard(_ session: ActivitySession, insight: ActivityInsight) -> some View {
        let lanes = insight.lanes(hours: 6)
        let names = insight.goalReport.map { ActivityReportPresentation.models($0) } ?? []
        let efforts = insight.goalReport.map { ActivityReportPresentation.efforts($0) } ?? []
        let activeLanes = lanes.filter { lane in
            ActivityPresentationPolicy.isRecent(lane.lastActivity, now: insight.now)
        }.count
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: insight.overview.pinnedSessionID == session.id ? "pin.fill" : "scope")
                    .font(.system(size: 9, weight: .semibold))
                Text(insight.overview.pinnedSessionID == session.id ? "Pinned goal" : "Open goal")
                Text("·")
                Text(ActivityFormat.project(session.projectPath))
                Spacer()
                if let goal = session.goal {
                    StatusDot(text: goal.status.capitalized, color: goal.status == "active" ? BridgeTheme.success : BridgeTheme.textTertiary, font: BridgeFont.micro)
                }
            }
            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary)

            Button { model.openActivityReports(sessionID: session.id) } label: {
                Text(ActivityFormat.headline(session.goal?.objective ?? session.title))
                    .font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                    .multilineTextAlignment(.leading).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help(session.goal?.objective ?? session.title)

            if let goal = session.goal, let goalReport = insight.goalReport {
                HStack(spacing: 0) {
                    timer("Recorded time", ActivityFormat.duration(goalReport.totals.activeSeconds), "Closed native intervals for this goal and its descendants, with overlaps counted once. Not continuous execution.")
                    Divider().frame(height: 26).overlay(BridgeTheme.separator)
                    timer("Local tokens", ActivityReportPresentation.tokens(goalReport), "Canonical local usage within this goal's span; not a provider goal or account counter.")
                    Divider().frame(height: 26).overlay(BridgeTheme.separator)
                    timer("Sessions", goalReport.totals.sessions.formatted(), "Sessions supported by canonical receipts or native intervals in this goal span.")
                }
                .padding(.vertical, 6)
                .bridgeWell()
                Text(ActivityReportPresentation.providerGoalCounter(goal))
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                    .help("A separate lifetime counter reported by the provider. Do not add it to local modeled usage. Open for \(ActivityFormat.duration(goal.age(at: insight.now))), including pauses.")
            }

            if lanes.contains(where: { !$0.intervals.isEmpty || !$0.openStarts.isEmpty }) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Last 6 hours").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                        Spacer()
                        Text("\(lanes.count) native lanes · \(activeLanes) recent")
                            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary)
                    }
                    GoalSwimlane(lanes: lanes, from: insight.now.addingTimeInterval(-6 * 3_600), to: insight.now,
                                 maxLanes: 9, laneHeight: 8, showLabels: false)
                }
            }

            if !names.isEmpty || !efforts.isEmpty {
                HStack(spacing: 5) {
                    ForEach(names.prefix(2), id: \.self) { Tag(text: ModelNaming.display($0)).help($0) }
                    ForEach(efforts.prefix(1), id: \.self) { Tag(text: ModelNaming.effort($0)) }
                    if names.count > 2 { Tag(text: "+\(names.count - 2) models").help(names.joined(separator: ", ")) }
                    Spacer(minLength: 0)
                }
            }
        }
        .bridgeCard(padding: 12)
    }

    private func timer(_ title: String, _ value: String, _ help: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(BridgeTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(title).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .help(help)
    }

    private var emptyGoal: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No open goal").font(BridgeFont.heading)
            Text(model.isRefreshingActivity ? "Reading your sessions and goals…" : "Goals appear when you give Codex a long-running objective. You can also pin any session in Agent Hub.")
                .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bridgeCard(padding: 12)
    }

    // MARK: Today

    private func todayGrid(_ insight: ActivityInsight) -> some View {
        let week = insight.daily7
        let agents = week.map { $0.sessionIDs.count }
        let current = insight.todayReport.totals
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: insight.snapshotDayTitle, icon: "sun.max")
                Spacer()
                Text("Saved native activity").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                KPITile(title: "Active time", value: ActivityFormat.duration(current.activeSeconds),
                        series: week.map(\.measuredActiveSeconds), tint: BridgeTheme.codex)
                    .help("The shared Core union of closed native intervals; includes waits and counts overlapping time once.")
                KPITile(title: "Local tokens", value: ActivityReportPresentation.tokens(insight.todayReport),
                        series: week.map { $0.measuredTokens.map(Double.init) }, tint: BridgeTheme.claude,
                        footnote: current.usageRecords > 0 ? "\(current.tokenReceipts)/\(current.usageRecords) usage records" : "Usage unmeasured")
                    .help("Same canonical local subtotal as Reports, Models and CLI. Interval-only usage can remain outside daily bars; account and goal counters are separate scopes.")
                KPITile(title: "Model steps", value: ActivityReportPresentation.steps(insight.todayReport),
                        series: week.map { $0.modelStepCount > 0 ? Double($0.modelStepCount) : nil }, tint: BridgeTheme.gemini)
                    .help("Observed responses and usage advances, not native turns, human prompts or exact billable attempts.")
                KPITile(title: "Saved sessions", value: insight.todayReport.isValid ? current.sessions.formatted() : "—",
                        series: agents.map(Double.init), tint: BridgeTheme.textSecondary)
                    .help("Sessions with supporting canonical receipts, native intervals or an open goal in this scope.")
            }
        }
    }

    @ViewBuilder
    private func workMix(_ insight: ActivityInsight) -> some View {
        let today = ActivityReportPresentation.mix(insight.todayReport)
        let shares = today.isEmpty ? ActivityReportPresentation.mix(insight.weekReport) : today
        if !shares.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle(text: "What the work involved", icon: "square.stack.3d.up")
                    Spacer()
                    Text(today.isEmpty ? "Last 7 days" : "Today").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
                WorkMixBar(shares: shares, maxLegend: 4)
            }
            .bridgeCard(padding: 12)
        }
    }

    // MARK: Agents

    @ViewBuilder
    private func recentAgents(_ insight: ActivityInsight) -> some View {
        let sessions = insight.overview.sessions.sorted { $0.updatedAt > $1.updatedAt }.prefix(4)
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle(text: "Recent agents", icon: "person.3")
                    Spacer()
                    Text("\(insight.overview.sessions.count) in total").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
                ForEach(Array(sessions)) { session in
                    let recent = insight.recentlyActive.contains { $0.id == session.id }
                    let own = insight.sessionReports[session.id]
                    let names = own.map { ActivityReportPresentation.models($0) } ?? []
                    Button { model.openActivityReports(sessionID: session.id) } label: {
                        HStack(spacing: 9) {
                            let assignment = PersonaDirectory.assignment(session.id, in: insight.overview)
                            AgentPortrait(persona: assignment?.persona, provider: session.provider, size: 28, recent: recent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                                HStack(spacing: 4) {
                                    if let role = assignment?.role {
                                        Image(systemName: role.symbol).font(.system(size: 8, weight: .semibold))
                                        Text(role.title)
                                        Text("·")
                                    }
                                    Text(names.first.map(ModelNaming.display) ?? "Model not recorded")
                                }
                                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                            }
                            Spacer(minLength: 4)
                            Text(ActivityFormat.relative(own.flatMap { ActivityReportPresentation.lastActivity($0) }, now: insight.now))
                                .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(recent ? BridgeTheme.success : BridgeTheme.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .bridgeCard(padding: 12)
        }
    }
}

enum BridgeWorkspaceLayout {
    static let minimumContentSize = NSSize(width: 960, height: 620)
}

@MainActor
final class ActivityReportsController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = ActivityReportsController(defaults: AcceptanceProbe.defaults)
    @Published private(set) var navigation: BridgeNavigationState
    @Published private(set) var isWindowVisible = false
    /// In full screen the titlebar band disappears, so pages add their own
    /// top margin instead of sitting against the screen edge.
    @Published private(set) var isFullScreen = ProcessInfo.processInfo.environment["BRIDGE_REPORTS_FULLSCREEN"] == "1" && AcceptanceProbe.isActive
    @Published private(set) var replaySelection: GoalReplaySelection?
    /// The turn open in the side drawer. It overlays the page instead of
    /// navigating, so the swimlane or card that was clicked stays in view.
    @Published private(set) var turnInspection: TurnInspectionSelection?
    /// The skill open on the Skills page; kept while visiting other pages.
    @Published var skillSelection: String?
    /// The Skills page shows instruction files instead of skills.
    @Published var skillsShowsInstructions = false
    /// The project open in the Skills page's instruction view.
    @Published var instructionSelection: String?
    private var forwardReplaySelection: GoalReplaySelection?
    private var window: NSWindow?
    private weak var model: BridgeViewModel?
    private let defaults: UserDefaults
    private let presentsWindows: Bool
    private(set) var windowCreationCount = 0
    var windowIdentity: ObjectIdentifier? { window.map(ObjectIdentifier.init) }
    var page: BridgePage { navigation.page }
    /// Retained views and minimized/occluded windows are not live readers.
    var isCreditSurfaceExposed: Bool {
        guard isWindowVisible, let window, NSApp?.isHidden != true else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }
    var canGoBack: Bool { turnInspection != nil || replaySelection != nil || navigation.canGoBack }
    var canGoForward: Bool { forwardReplaySelection != nil || navigation.canGoForward }
    var selectedSessionID: String? {
        get { navigation.selectedSessionID }
        set {
            // One trailing panel at a time: session details replace the drawer.
            if newValue != nil { turnInspection = nil }
            navigation.selectSession(newValue)
        }
    }

    init(defaults: UserDefaults = .standard, presentsWindows: Bool = true) {
        self.defaults = defaults
        self.presentsWindows = presentsWindows
        navigation = BridgeNavigationState(restoredPage: defaults.string(forKey: "bridge.workspace.page") ?? defaults.string(forKey: "activityReports.section.v2"))
        super.init()
    }

    func navigate(to page: BridgePage) {
        PerfTrace.navigation(page.rawValue)
        replaySelection = nil; forwardReplaySelection = nil; turnInspection = nil
        navigation.navigate(to: page)
        selectionChanged()
    }
    /// Opens a skill on the Skills page, from a turn or any other page.
    func showSkill(_ key: String) {
        skillSelection = key
        skillsShowsInstructions = false
        navigate(to: .skills)
    }
    func goBack() {
        if turnInspection != nil { turnInspection = nil; return }
        if let replaySelection { forwardReplaySelection = replaySelection; self.replaySelection = nil }
        else { forwardReplaySelection = nil; navigation.goBack() }
        selectionChanged()
    }
    func goForward() {
        turnInspection = nil
        if let forwardReplaySelection { replaySelection = forwardReplaySelection; self.forwardReplaySelection = nil }
        else { replaySelection = nil; navigation.goForward() }
        selectionChanged()
    }
    func openReplay(overview: ActivityOverview, sessionID: String, focusTurnIDs: [String] = []) {
        let root = Self.replayRoot(in: overview, selectedID: sessionID)
        // Replay is a detail route of the current reporting page. Keeping the
        // origin mounted makes Back restore the exact scroll/control state.
        if !navigation.page.needsActivityCollection { navigation.navigate(to: .goals) }
        forwardReplaySelection = nil; turnInspection = nil
        replaySelection = GoalReplaySelection(overview: overview, rootSessionID: root,
                                             focusSessionID: sessionID, focusTurnIDs: focusTurnIDs)
        selectionChanged()
    }
    /// Opens the drawer on one recorded turn; nil picks the session's latest.
    /// The snapshot is frozen here so a refresh can't move what is being read.
    func inspectTurn(overview: ActivityOverview, sessionID: String, turnID: String? = nil, snapshotRevision: UInt64? = nil) {
        guard replaySelection == nil, overview.sessions.contains(where: { $0.id == sessionID }) else { return }
        navigation.selectSession(nil)
        turnInspection = TurnInspectionSelection(overview: overview, sessionID: sessionID, turnID: turnID,
                                                snapshotRevision: snapshotRevision ?? model?.activityRevision ?? 0)
    }
    /// Moves the open drawer to another turn of the same session.
    func focusTurn(_ turnID: String) {
        guard var current = turnInspection, current.turnID != turnID,
              current.overview.sessions.contains(where: { $0.id == current.sessionID && $0.turns.contains(where: { $0.id == turnID }) }) else { return }
        current.turnID = turnID
        turnInspection = current
    }
    func closeTurnInspection() { turnInspection = nil }
    /// Keeps an open drawer on its turn as the page's snapshot advances.
    func rebaseTurnInspection(on overview: ActivityOverview, revision: UInt64 = 0) {
        guard let current = turnInspection, let newer = current.rebased(on: overview, revision: revision) else { return }
        turnInspection = newer
    }

    /// Closed goals are navigable too. Only explicit provider-safe parent
    /// identities are followed; shared folders/titles never create a link.
    static func replayRoot(in overview: ActivityOverview, selectedID: String) -> String {
        let groups = Dictionary(grouping: overview.sessions, by: \.id)
        guard let selectedRows = groups[selectedID], selectedRows.count == 1, let selected = selectedRows.first else { return selectedID }
        var cursor = selected, visited: Set<String> = [selected.id]
        func ownsGoal(_ session: ActivitySession) -> Bool {
            guard let goal = session.goal else { return false }
            if goal.sessionID == session.id { return true }
            let owners = overview.sessions.filter { $0.provider == session.provider && $0.nativeID == goal.sessionID }
            return owners.count == 1 && owners.first?.id == session.id
        }
        while !ownsGoal(cursor), let parentID = cursor.parentSessionID {
            let candidates = groups[parentID] ?? overview.sessions.filter { $0.provider == selected.provider && $0.nativeID == parentID }
            guard candidates.count == 1, let parent = candidates.first, parent.provider == selected.provider,
                  parent.createdAt <= overview.generatedAt, parent.observedAt <= overview.generatedAt,
                  visited.insert(parent.id).inserted else { return selectedID }
            cursor = parent
        }
        return ownsGoal(cursor) ? cursor.id : selectedID
    }
    private func selectionChanged() {
        defaults.set(page.rawValue, forKey: "bridge.workspace.page")
        model?.observeActivity("reports", visible: isWindowVisible && page.needsActivityCollection)
    }

    func show(model: BridgeViewModel, page: BridgePage? = nil, sessionID: String? = nil) {
        self.model = model
        if let sessionID {
            replaySelection = nil; forwardReplaySelection = nil; turnInspection = nil
            navigation.openSession(sessionID)
        } else if let page { replaySelection = nil; forwardReplaySelection = nil; turnInspection = nil; navigation.navigate(to: page) }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = BridgeBrand.productName
            // The sidebar runs under the traffic lights; pages keep the
            // titlebar band as drag space, so the minimum adds it back.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            let titlebar = max(0, window.frame.height - window.contentLayoutRect.height)
            window.contentMinSize = NSSize(width: BridgeWorkspaceLayout.minimumContentSize.width,
                                           height: BridgeWorkspaceLayout.minimumContentSize.height + titlebar)
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(BridgeTheme.ink)
            window.isReleasedWhenClosed = false
            window.tabbingMode = .disallowed
            window.delegate = self
            window.contentView = NSHostingView(rootView: ActivityReportsView(model: model, navigation: self).defaultAppStorage(AcceptanceProbe.defaults))
            if AcceptanceProbe.isActive {
                let fixture = ProcessInfo.processInfo.environment["BRIDGE_GOAL_REPLAY_PREVIEW"] == "1"
                window.title = "\(BridgeBrand.productName) · \(fixture ? "Fixture" : RefreshAcceptance.isReplayMode ? "Replay" : "Live metadata") test"
            }
            if presentsWindows && !AcceptanceProbe.isActive { window.setFrameAutosaveName("BridgeActivityReports.v1") }
            // Old saved frames used a 620pt *outer* minimum, clipping the
            // footer after the native titlebar consumed part of that height.
            let minimumFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
            var restoredFrame = window.frame
            restoredFrame.size.width = max(restoredFrame.width, minimumFrame.width)
            restoredFrame.size.height = max(restoredFrame.height, minimumFrame.height)
            window.setFrame(restoredFrame, display: false)
            window.center()
            self.window = window
            windowCreationCount += 1
        }
        guard presentsWindows else { selectionChanged(); return }
        MenuBarController.shared.close()
        isWindowVisible = true
        selectionChanged()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        if SnapshotCapture.isActive {
            // Snapshot renders must not take focus from whatever the person
            // is typing into.
            window?.orderFrontRegardless()
        } else {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
    }

    func close() { window?.close(); isWindowVisible = false; selectionChanged() }
    func windowWillClose(_ notification: Notification) { isWindowVisible = false; selectionChanged() }
    func windowDidMiniaturize(_ notification: Notification) { isWindowVisible = false; selectionChanged() }
    func windowDidDeminiaturize(_ notification: Notification) { isWindowVisible = true; selectionChanged() }
    func windowWillEnterFullScreen(_ notification: Notification) { isFullScreen = true }
    func windowDidExitFullScreen(_ notification: Notification) { isFullScreen = false }

    func showPreview(model: BridgeViewModel) {
        // Preview only: pick the report period ("24 hours", "7 days", ...).
        if let period = ProcessInfo.processInfo.environment["BRIDGE_REPORTS_PERIOD"], ReportPeriod(rawValue: period) != nil {
            AcceptanceProbe.defaults.set(period, forKey: "activityReports.period")
        }
        if let section = ProcessInfo.processInfo.environment["BRIDGE_REPORTS_SECTION"] {
            navigate(to: BridgePage.restored(section))
        }
        // Preview only: open the Skills page on its instruction files.
        if ProcessInfo.processInfo.environment["BRIDGE_SKILLS_VIEW"] == "instructions" { skillsShowsInstructions = true }
        if let project = ProcessInfo.processInfo.environment["BRIDGE_INSTRUCTIONS_PROJECT"], !project.isEmpty { instructionSelection = project }
        if let skill = ProcessInfo.processInfo.environment["BRIDGE_SKILLS_SELECT"], !skill.isEmpty { skillSelection = skill }
        show(model: model)
        if let size = ProcessInfo.processInfo.environment["BRIDGE_REPORTS_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            window?.setContentSize(NSSize(width: size[0], height: size[1]))
        }
        // Preview only: visit pages in turn once the first snapshot has
        // arrived, for timing page changes with BRIDGE_PERF_TRACE.
        if let tour = ProcessInfo.processInfo.environment["BRIDGE_PERF_TOUR"], !tour.isEmpty {
            let pages = tour.split(separator: ",").map { BridgePage.restored(String($0)) }
            let interval = Double(ProcessInfo.processInfo.environment["BRIDGE_PERF_TOUR_INTERVAL"] ?? "") ?? 3
            Task { @MainActor [weak self, weak model] in
                for _ in 0 ..< 240 {
                    guard let model else { return }
                    if model.activityOverview.generatedAt != .distantPast { break }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                for page in pages {
                    guard let self else { return }
                    self.navigate(to: page)
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
                PerfTrace.mark("tour-done")
            }
        }
        // Preview only: open the turn drawer on a goal's (or a session's)
        // latest turn once the first snapshot has arrived.
        if let target = ProcessInfo.processInfo.environment["BRIDGE_REPORTS_INSPECT"], !target.isEmpty {
            Task { @MainActor [weak self, weak model] in
                for _ in 0 ..< 240 {
                    guard let self, let model else { return }
                    let overview = model.activityOverview
                    if overview.generatedAt != .distantPast {
                        let id = target == "goal" ? overview.sessions.first(where: { $0.goal != nil })?.id : target
                        if let id { self.inspectTurn(overview: overview, sessionID: id) }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }
        guard let path = ProcessInfo.processInfo.environment["BRIDGE_REPORTS_SNAPSHOT"], !path.isEmpty else { return }
        let delay = ProcessInfo.processInfo.environment["BRIDGE_UI_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 3
        // Preview only: scroll the page so long pages can be captured in parts
        // without screen recording. The page is the scroll view with the
        // largest visible frame; nested lists can have taller content.
        if let offset = ProcessInfo.processInfo.environment["BRIDGE_REPORTS_SCROLL"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.5, delay - 1)) { [weak self] in
                guard let root = self?.window?.contentView else { return }
                var found: [NSScrollView] = []
                var stack: [NSView] = [root]
                while let view = stack.popLast() {
                    if let scroll = view as? NSScrollView { found.append(scroll) }
                    stack.append(contentsOf: view.subviews)
                }
                guard let scroll = found.filter({ ($0.documentView?.frame.height ?? 0) > $0.frame.height })
                        .max(by: { $0.frame.height * $0.frame.width < $1.frame.height * $1.frame.width }) else { return }
                let flipped = scroll.documentView?.isFlipped ?? true
                let height = scroll.documentView?.frame.height ?? 0
                let y = flipped ? offset : max(0, height - scroll.contentView.bounds.height - offset)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // The frame view includes the traffic lights over the sidebar.
            guard let content = self?.window?.contentView, case let view = content.superview ?? content,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }
}

struct ActivitySessionInspector: View {
    var session: ActivitySession
    var overview: ActivityOverview
    @ObservedObject var model: BridgeViewModel
    var snapshotRevision: UInt64? = nil
    /// Commits linked to sessions in the current view, when projects were scanned.
    var shipped: ShippedCodeReport.Result? = nil
    var selectSession: (String) -> Void
    var close: () -> Void
    @AppStorage("bridge.showPersonas") private var showPersonas = true
    @State private var projectionCache = InspectorAccountingCache()
    private var prepared: InspectorPreparedPresentation {
        projectionCache.prepared(sessionID: session.id, overview: overview, revision: snapshotRevision ?? model.activityRevision)
    }
    private var accounting: ActivityAccounting.Report {
        prepared.ownWork
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Session").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textSecondary)
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(BridgeIconButtonStyle())
                        .keyboardShortcut(.cancelAction).accessibilityLabel("Close session details")
                }
                identity
                summary
                Button {
                    Task { @MainActor in ActivityReportsController.shared.openReplay(overview: overview, sessionID: session.id) }
                } label: { Label("Open step-by-step replay", systemImage: "list.number") }
                    .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                if let goal = session.goal { goalSection(goal) }
                commitsSection
                connections
                Divider()
                technicalDetails
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }.background(BridgeTheme.inkRaised).onDisappear { projectionCache.reset() }
    }

    /// Commits linked to this session, with their lines and evidence.
    @ViewBuilder private var commitsSection: some View {
        if let shipped, let output = shipped.sessions[session.id], !output.commitIDs.isEmpty {
            let ids = Set(output.commitIDs)
            let commits = shipped.commits.filter { ids.contains($0.commit.id) && $0.sessionIDs.contains(session.id) }
            let sessions = Dictionary(overview.sessions.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs })
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Linked commits").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                    LinesChangedLabel(lines: output.lines, compact: true, font: BridgeFont.captionMedium)
                    Spacer()
                    InfoButton(title: "Linked commits", text: shipped.notes.dropFirst().first ?? "")
                }
                ForEach(commits.prefix(8)) { commit in
                    ShippedCommitRow(commit: commit, sessions: sessions, now: overview.generatedAt, showSession: selectSession)
                }
                if commits.count > 8 {
                    Text("+ \(commits.count - 8) more").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
            }
        }
    }

    private var identity: some View {
        let assignment = PersonaDirectory.assignment(session.id, in: overview)
        let recent = ActivityPresentationPolicy.isRecent(prepared.lastActivityBySession[session.id], now: Date())
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                AgentPortrait(persona: assignment?.persona, provider: session.provider, size: 52, recent: recent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title).font(.system(size: 16, weight: .semibold)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let assignment {
                        Label(showPersonas ? assignment.persona.map { "\($0.fullName) · \(assignment.role.title)" } ?? assignment.role.title : assignment.role.title,
                              systemImage: assignment.role.symbol)
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                            .help(assignment.role.explanation + " The portrait is decorative.")
                    }
                }
            }
            HStack(spacing: 6) {
                Tag(text: session.provider == .codex ? "Codex" : session.provider.rawValue.capitalized, color: BridgeTheme.color(for: session.provider))
                if session.isChild { Tag(text: "Sub-agent") }
                if recent {
                    Tag(text: "Recent", color: BridgeTheme.success)
                        .help("Recent saved evidence, not a live process check.")
                }
                Spacer()
                Button {
                    model.pinActivity(overview.pinnedSessionID == session.id ? nil : session.id)
                } label: {
                    Label(overview.pinnedSessionID == session.id ? "Unpin" : "Pin to menu bar", systemImage: overview.pinnedSessionID == session.id ? "pin.slash" : "pin")
                }
                .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                .help("Show this session in the menu-bar panel")
            }
        }
    }

    private var summary: some View {
        let report = accounting
        let totals = report.totals
        let mix = ActivityReportPresentation.mix(report)
        let models = ActivityReportPresentation.models(report)
        let efforts = ActivityReportPresentation.efforts(report)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Text("Own recorded work · all saved dates")
                    .font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textSecondary)
                InfoButton(title: "Own recorded work", text: "Canonical local accounting as of the saved snapshot. Copied parent work is excluded; provider goal counters below use a separate scope.")
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                tile(ActivityReportPresentation.steps(report), "model steps", "bubble.left.and.text.bubble.right")
                tile(totals.nativeRecords.formatted(), "requests", "doc.text")
                tile(ActivityFormat.duration(totals.activeSeconds), "active time", "clock")
                tile(ActivityReportPresentation.tokens(report), "tokens", "circle.hexagongrid")
                tile(ActivityReportPresentation.tokens(report, output: true), "written tokens", "pencil.line")
                tile(totals.toolCalls.map { $0.formatted() } ?? "—", "tool uses", "wrench.and.screwdriver")
            }
            if !mix.isEmpty { WorkMixBar(shares: mix, maxLegend: 3) }
            if !models.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "cpu").font(.system(size: 10)).foregroundStyle(BridgeTheme.textTertiary)
                    ForEach(models.prefix(3), id: \.self) { Tag(text: ModelNaming.display($0)).help($0) }
                    ForEach(efforts.prefix(2), id: \.self) { Tag(text: ModelNaming.effort($0)) }
                }
            }
            Text("Started \(session.createdAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                .help("Session started: \(ActivityReportPresentation.exactActivityDate(session.createdAt))")
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let lastActivity = prepared.lastActivityBySession[session.id]
                Text(ActivityReportPresentation.recordedActivityLabel(lastActivity, now: context.date))
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    .help(ActivityReportPresentation.recordedActivityHelp(lastActivity))
                    .accessibilityLabel(ActivityReportPresentation.recordedActivityHelp(lastActivity))
            }
            if !session.historyComplete {
                Label("Only part of this session's history was available, so these numbers are minimums.", systemImage: "clock.badge.questionmark")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(BridgeTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Label(label, systemImage: icon).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).bridgeWell()
    }

    private func goalSection(_ goal: ActivityGoal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            SectionTitle(text: "Provider goal counter · \(goal.status.capitalized)", icon: "scope")
            Text(goal.objective).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textPrimary).textSelection(.enabled)
                .lineLimit(8).fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: 8) {
                    tile(ActivityFormat.duration(goal.age(at: context.date), style: .clock), "open for", "clock")
                    tile(ActivityFormat.duration(goal.providerTimeSeconds, style: .clock), "provider goal time", "timer")
                }
            }
            if let used = goal.tokensUsed {
                Text(goal.tokenBudget.map { "Provider goal counter: \(ActivityFormat.compact(used)) of \(ActivityFormat.compact($0)) tokens" } ?? "Provider goal counter: \(ActivityFormat.compact(used)) tokens")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            }
            Text("Lifetime provider-reported goal counters; not the local token subtotal above and not added to it.")
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connections: some View {
        let presentation = prepared
        let childSessions = presentation.descendants
        return VStack(alignment: .leading, spacing: 8) {
            if session.projectPath != nil || session.parentSessionID != nil || !childSessions.isEmpty { Divider() }
            if let path = session.projectPath {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(BridgeTheme.textTertiary)
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(BridgeFont.mono).foregroundStyle(BridgeTheme.textSecondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    Spacer()
                    Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(BridgeIconButtonStyle()).help("Show in Finder").accessibilityLabel("Show project in Finder")
                }
            }
            if let parent = ActivityAnalytics.sessionParents(in: overview.sessions)[session.id],
               let parentSession = overview.sessions.first(where: { $0.id == parent }) {
                Button { selectSession(parentSession.id) } label: {
                    Label("Started by \(parentSession.title)", systemImage: "arrow.turn.left.up").font(BridgeFont.caption).lineLimit(1)
                }
                .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
            }
            if !childSessions.isEmpty {
                SectionTitle(text: "\(childSessions.count) sub-\(childSessions.count == 1 ? "agent" : "agents")", icon: "arrow.turn.down.right")
                    .help("All saved descendants of this session, not a count of currently running agents.")
                Text("All saved dates · latest recorded activity first")
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(childSessions.prefix(12)) { child in
                            let lastActivity = presentation.lastActivityBySession[child.id]
                            Button { selectSession(child.id) } label: {
                                HStack(spacing: 8) {
                                    AgentPortrait(persona: PersonaDirectory.assignment(child.id, in: overview)?.persona, provider: child.provider, size: 20, showBadge: false)
                                    Text(child.title).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                                    Spacer()
                                    Text(lastActivity.map { ActivityFormat.relative($0, now: context.date) } ?? "Not dated")
                                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                                        .fixedSize(horizontal: true, vertical: false)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(ActivityReportPresentation.recordedActivityHelp(lastActivity))
                            .accessibilityLabel(child.title)
                            .accessibilityValue(ActivityReportPresentation.recordedActivityHelp(lastActivity))
                        }
                    }
                }
                if childSessions.count > 12 { Text("+\(childSessions.count - 12) more").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary) }
            }
        }
    }

    private var technicalDetails: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Raw provider history · all saved dates. These records may include copied parent work and pooled counters; they are not the canonical model-step totals above.")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                value("Session ID", session.nativeID)
                Button("Copy session ID") { ActivityDisplay.copy(session.nativeID) }.buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand)).font(.caption)
                value("Live state", ActivityDisplay.state(session.runtimeState))
                value("Raw usage coverage", "\(session.turns.filter { $0.usage.total != nil }.count) of \(session.turns.count) native records carry a token pool; \(session.turns.filter { $0.usageIsPartial == true }.count) are partial pools.")
                value("Raw provider prompt counters", ActivityDisplay.count(ActivityMetrics.knownTotal(session.turns.map(\.promptCount))) + " submitted · " + ActivityDisplay.count(ActivityMetrics.knownTotal(session.turns.map(\.humanPromptCount))) + " confirmed from a person")
                value("Raw native durations (summed)", ActivityDisplay.duration(ActivityMetrics.summedSeconds(session.turns)))
                value("Native history model labels", session.models.joined(separator: ", ").ifEmpty("Not recorded"))
                value("Native history effort labels", session.efforts.joined(separator: ", ").ifEmpty("Not recorded"))
                if session.parentSessionID != nil {
                    Text("A sub-agent's saved history can include copies of its parent's requests. Agent cards and timelines leave those out.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Latest \(min(50, session.turns.count)) of \(session.turns.count) raw native records") {
                    ForEach(Array(session.turns.suffix(50).reversed())) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(turn.startedAt?.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) ?? "Start not recorded").font(.caption.weight(.medium))
                                Spacer()
                                Text(turn.status.capitalized).font(.caption2).foregroundStyle(turn.status == "failed" ? BridgeTheme.danger : .secondary)
                            }
                            Text("Native label: \(turn.model.map(ModelNaming.display) ?? "not recorded") · \(ActivityDisplay.duration(turn.durationSeconds).replacingOccurrences(of: "Unavailable", with: "—")) · raw pool \(ActivityFormat.compact(turn.usage.total)) tokens")
                                .font(.caption2).foregroundStyle(.secondary)
                            if !turn.categories.isEmpty {
                                Text("Tools: " + turn.categories.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            ForEach(turn.artifacts) { artifact in
                                Text("\(artifact.kind): \(artifact.path)").font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            Divider()
                        }.padding(.vertical, 4)
                    }
                    if session.turns.count > 50 { Text("Use Explore steps & results for a bounded history read. The native conversation remains the original source.").font(.caption).foregroundStyle(.secondary) }
                }
                .font(.caption.weight(.medium))
                value("Source", session.source)
                value("Read", session.observedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                ForEach(session.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.top, 8)
        } label: {
            Label("Technical details", systemImage: "wrench.and.screwdriver").font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textSecondary)
        }
    }

    private func value(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One goal as a story: what it is, how long it has run, which agents worked
/// when, how many ran at once, and what they produced.
struct GoalDetailCard: View {
    var session: ActivitySession
    var overview: ActivityOverview
    var snapshotRevision: UInt64
    var selectSession: (String) -> Void
    @State private var range: GoalRange = .day
    @State private var group: SwimGroup = .none
    @State private var showObjective = false
    @ObservedObject private var store = GoalPresentationStore.shared
    @AppStorage("bridge.showPersonas") private var showPersonas = true
    @Environment(\.activityContentVisible) private var contentVisible
    @State private var inspectionClock = Date()

    enum GoalRange: String, CaseIterable, Identifiable {
        case six = "6h", day = "24h", three = "72h", all = "Since start"
        var id: String { rawValue }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            content(now: contentVisible ? context.date : inspectionClock)
        }
        .onChange(of: contentVisible) { visible in if !visible { inspectionClock = Date() } }
        .task(id: preparationKey) { await store.prepare(overview: overview, key: preparationKey) }
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            let scope = "goal:" + session.id
            guard AcceptanceProbe.isActive, AcceptanceProbe.requestScope(note) == scope else { return }
            let name = AcceptanceProbe.requestName(note)
            let supported = name == "exercise.safe" || name == "report"
            if name == "exercise.safe" {
                range = .six; group = .role
                if (session.goal?.objective.count ?? 0) > 160 { showObjective = true }
            }
            AcceptanceProbe.record(note, scope: scope,
                state: ["range": range.rawValue, "group": group.rawValue, "objective": String(showObjective),
                        "objectiveApplicable": String((session.goal?.objective.count ?? 0) > 160)], supported: supported)
        }
    }

    private func window(now: Date) -> (Date, Date) {
        let created = min(session.goal?.createdAt ?? session.createdAt, now)
        switch range {
        case .six: return (max(created, now.addingTimeInterval(-6 * 3_600)), now)
        case .day: return (max(created, now.addingTimeInterval(-86_400)), now)
        case .three: return (max(created, now.addingTimeInterval(-3 * 86_400)), now)
        case .all: return (created, now)
        }
    }

    private func key(now: Date) -> GoalAccountingCache.Key {
        let (from, to) = window(now: min(now, overview.generatedAt))
        return GoalAccountingCache.Key(sessionID: session.id, revision: snapshotRevision, asOf: overview.generatedAt, from: from, to: to)
    }
    private var preparationKey: GoalAccountingCache.Key { key(now: contentVisible ? Date() : inspectionClock) }

    @ViewBuilder
    private func content(now: Date) -> some View {
        // The story for this snapshot and range, else this goal's previous
        // story (drawn with its own window) while the new one is prepared.
        if let entry = store.entry(for: key(now: now)) ?? store.latest(for: session.id) {
            story(entry.value, from: entry.key.from, to: entry.key.to, now: now)
        } else {
            ActivityLoadingView(page: .goals, message: "Preparing this goal…")
        }
    }

    @ViewBuilder
    private func story(_ prepared: GoalPreparedPresentation, from: Date, to: Date, now: Date) -> some View {
        let lanes = prepared.lanes
        let curve = prepared.curve
        let report = prepared.report
        let artifacts = prepared.artifacts
        let goal = session.goal
        let assignment = prepared.assignments[session.id]
        let recentLanes = prepared.lastActivityBySession.values.filter { ActivityPresentationPolicy.isRecent($0, now: now) }.count

        VStack(alignment: .leading, spacing: 16) {
            goalHeader(goal, assignment: assignment, recent: ActivityPresentationPolicy.isRecent(prepared.lastActivityBySession[session.id], now: now), now: now, models: prepared.modelsBySession[session.id] ?? [], efforts: prepared.effortsBySession[session.id] ?? [])

            StatStrip(items: [
                .init(value: ActivityFormat.duration(report.totals.activeSeconds, style: .clock), label: "active time", icon: "timer",
                      help: "Canonical local closed intervals in this range, overlaps counted once; includes waits."),
                .init(value: ActivityReportPresentation.tokens(report), label: "tokens", icon: "circle.hexagongrid", help: "Canonical local usage in this range; provider goal counters are separate."),
                .init(value: ActivityReportPresentation.steps(report), label: "model steps", icon: "bubble.left.and.text.bubble.right", help: "Observed model responses and usage advances, not native records or human prompts."),
                .init(value: "\(recentLanes)", label: "recent sessions", icon: "waveform.path", color: recentLanes > 0 ? BridgeTheme.success : BridgeTheme.textPrimary,
                      help: "Sessions with dated canonical evidence in the last 15 minutes; not a live process check."),
                .init(value: lanes.contains(where: { !$0.intervals.isEmpty }) ? "\(curve.map(\.agents).max() ?? 0)" : "—", label: "most at once", icon: "square.stack.3d.up",
                      help: "The most agents working at the same moment in this range"),
            ])
            .padding(.vertical, 12)
            .bridgeWell(cornerRadius: 10)
            if let goal {
                HStack(spacing: 6) {
                    Image(systemName: "scope").font(.system(size: 10, weight: .semibold)).foregroundStyle(BridgeTheme.success)
                    Text("Whole goal, as \(ActivityTitles.providerName(session.provider)) counts it").foregroundStyle(BridgeTheme.textTertiary)
                    Text("\(ActivityFormat.compact(goal.tokensUsed)) tokens · \(ActivityFormat.duration(goal.providerTimeSeconds))")
                        .foregroundStyle(BridgeTheme.textSecondary).monospacedDigit()
                }
                .font(BridgeFont.caption)
                .help(ActivityReportPresentation.providerGoalCounter(goal) + " · lifetime scope. Reported by the provider for the goal, including work outside the selected range. Not added to local usage.")
                .accessibilityElement(children: .combine)
            }

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        SectionTitle(text: "Agent swimlanes", icon: "rectangle.split.3x1")
                        Text("Click a block to inspect its turn · ◆ grouped turns · ○ end not recorded")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { groupingControl; Spacer(minLength: 12); rangeControl }
                        VStack(alignment: .leading, spacing: 8) { groupingControl; rangeControl }
                    }
                }
                if lanes.allSatisfy({ $0.intervals.isEmpty && $0.openStarts.isEmpty }) {
                    Text("No recorded intervals in this range.").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    WorkSwimlanes(lanes: lanes, overview: overview, from: from, to: to, now: now, group: group, maxRows: 16,
                        preparedAssignments: prepared.assignments, preparedLoad: prepared.load, snapshotRevision: snapshotRevision, select: selectSession)
                    categoryLegend(prepared.categoryLegend)
                }
            }

            let laneIDs = Set(lanes.map(\.id))
            GoalTurnsSection(sessions: overview.sessions.filter { laneIDs.contains($0.id) },
                             laneTitles: Dictionary(lanes.map { lane in
                                 (lane.id, lane.isParent ? "Goal session" : ActivityTitles.display(lane.title, provider: lane.provider, projectPath: session.projectPath))
                             }, uniquingKeysWith: { first, _ in first }),
                             assignments: prepared.assignments, overview: overview, from: from, to: to, now: now,
                             revision: snapshotRevision)


            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "Agents · by active time", icon: "person.3")
                    let roster = lanes.dropFirst().sorted { $0.busySeconds > $1.busySeconds }.prefix(10)
                    if roster.isEmpty { Text("No sub-agents in this range.").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary) }
                    ForEach(Array(roster)) { lane in
                        let model: String? = prepared.modelsBySession[lane.id]?.first
                        let modelLabel: String = model.map { ModelNaming.display($0) } ?? "Model not recorded"
                        Button { selectSession(lane.id) } label: {
                            HStack(spacing: 8) {
                                let laneAssignment = prepared.assignments[lane.id]
                                AgentPortrait(persona: laneAssignment?.persona, provider: lane.provider, size: 28,
                                              recent: ActivityPresentationPolicy.isRecent(lane.lastActivity, now: now))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(lane.title).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                                    HStack(spacing: 5) {
                                        if let role = laneAssignment?.role {
                                            Label(role.title, systemImage: role.symbol).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary)
                                        }
                                        Text(modelLabel)
                                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(BridgeTheme.textTertiary)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(ActivityFormat.duration(report.sessionWorkSeconds[lane.id])).font(BridgeFont.captionMedium.monospacedDigit())
                                    Text(ActivityFormat.relative(prepared.lastActivityBySession[lane.id], now: now)).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "Outputs in selected range", icon: "shippingbox")
                    let mix = prepared.mix
                    if !mix.isEmpty { WorkMixBar(shares: mix, maxLegend: 3) }
                    if artifacts.isEmpty {
                        Text("No file artifacts recorded for this goal. Codex history does not yet expose file changes here; use Projects for Git evidence.")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(Array(artifacts.prefix(10))) { artifact in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(BridgeTheme.textTertiary)
                                Text(artifact.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                                Spacer()
                                Text(artifact.status.replacingOccurrences(of: "_", with: " ")).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                            }
                        }
                        if artifacts.count > 10 { Text("+\(artifacts.count - 10) more").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(18)
        .background(BridgeTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(BridgeTheme.surfaceBorder, lineWidth: 1))
    }

    private func goalHeader(_ goal: ActivityGoal?, assignment: AgentPersonaCatalog.Assignment?, recent: Bool, now: Date, models: [String], efforts: [String]) -> some View {
        let active = goal?.status == "active"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                AgentPortrait(persona: assignment?.persona, provider: session.provider, size: 38, recent: recent)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        CapsChip(text: goal?.status ?? "unknown", color: active ? BridgeTheme.success : BridgeTheme.textTertiary,
                                 icon: active ? "bolt.fill" : "pause.fill").fixedSize()
                        if let age = goal?.age(at: now) {
                            Text("Open \(ActivityFormat.duration(age))").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                                .help("Time since the goal was set, including pauses")
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        goalMeta(assignment: assignment, includePersona: true, models: models, efforts: efforts)
                        goalMeta(assignment: assignment, includePersona: false, models: models, efforts: efforts)
                    }
                }
                Spacer(minLength: 8)
                Button { selectSession(session.id) } label: { Label("Details", systemImage: "sidebar.right") }
                    .buttonStyle(BridgeSecondaryButtonStyle(compact: true)).fixedSize()
                    .help("Open this goal's session details")
                Button {
                    Task { @MainActor in ActivityReportsController.shared.openReplay(overview: overview, sessionID: session.id) }
                } label: { Label("Replay", systemImage: "list.number") }
                    .buttonStyle(BridgeSecondaryButtonStyle(compact: true)).help("Open the goal and its helper sessions in chronological order")
                    .accessibilityLabel("Open goal replay")
            }
            Text(ActivityFormat.headline(goal?.objective ?? session.title, limit: 180))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(BridgeTheme.textPrimary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if let objective = goal?.objective, objective.count > 160 {
                Button(showObjective ? "Hide full objective" : "Show full objective") {
                    withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.2)) { showObjective.toggle() }
                }.buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
                if showObjective {
                    Text(objective).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading).bridgeWell()
                }
            }
        }
    }

    /// Project, model, effort and persona on one icon-led line.
    private func goalMeta(assignment: AgentPersonaCatalog.Assignment?, includePersona: Bool, models: [String], efforts: [String]) -> some View {
        HStack(spacing: 12) {
            Label(ActivityFormat.project(session.projectPath), systemImage: "folder")
                .lineLimit(1).truncationMode(.middle).help(session.projectPath ?? "Project unavailable")
            if let model = models.first {
                Label(ModelNaming.display(model), systemImage: "cpu").foregroundStyle(BridgeTheme.color(for: session.provider)).help(model)
            }
            if let effort = efforts.first {
                Label(ModelNaming.effort(effort), systemImage: "gauge.with.dots.needle.50percent").help("Reasoning effort")
            }
            if includePersona, showPersonas, let persona = assignment?.persona {
                Label("\(persona.firstName) · \(assignment?.role.title ?? "Coordinator")", systemImage: assignment?.role.symbol ?? "person")
                    .help("Decorative persona from the WorkspaceOps roster")
            }
        }
        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
        .labelStyle(CompactLabelStyle())
        .fixedSize()
    }

    /// Legend for the categories actually present in the visible lanes.
    private func categoryLegend(_ ordered: [(name: String, count: Int)]) -> some View {
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), alignment: .leading)], alignment: .leading, spacing: 8) {
            ForEach(ordered.prefix(7), id: \.name) { name, count in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(name == "Tools not recorded" ? BridgeTheme.codex : BridgeTheme.category(name)).frame(width: 9, height: 9)
                    Image(systemName: BridgeTheme.categorySymbol(name)).font(.system(size: 9, weight: .semibold))
                    Text(name)
                    Text("\(count)").monospacedDigit().foregroundStyle(BridgeTheme.textTertiary)
                }
                .help(name == "Tools not recorded" ? "These native intervals didn't record tools, so they're drawn in the provider colour." : "\(count) native interval segments with \(name.lowercased()) as the main kind of work")
            }
        }
        .font(BridgeFont.micro)
        .foregroundStyle(BridgeTheme.textSecondary)
    }

    private var groupingControl: some View {
        HStack(spacing: 6) {
            Text("Group").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            Picker("Group", selection: $group) { ForEach(SwimGroup.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
        }
    }

    private var rangeControl: some View {
        Picker("Range", selection: $range) { ForEach(GoalRange.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().frame(width: 250)
    }
}
