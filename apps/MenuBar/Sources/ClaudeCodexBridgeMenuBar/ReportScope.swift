import BridgeCore
import Foundation
import Combine

/// Everything the Hub's activity pages derive from one snapshot and one set of
/// filters. Building it walks every saved turn, so the window builds it once
/// per change of inputs instead of on every redraw.
struct ReportScope {
    struct Key: Equatable, Sendable {
        var generatedAt: Date
        var sessionCount: Int
        var pinnedSessionID: String?
        var provider: String
        var project: String
        var query: String
        var cutoff: Date?
        var now: Date
        /// Same-timestamp corrections and local mutations are valid snapshots.
        /// Their contents, not just collection time/count, must expire memoized data.
        var snapshotRevision: UInt64 = 0
    }

    /// Sessions matching provider, project and search, before date scoping, so
    /// previous-period comparisons still see sessions that were only active then.
    let matchingSessions: [ActivitySession]
    /// Matching sessions with evidence in the period (open goals always stay).
    let sessions: [ActivitySession]
    /// Deduplicated turns of `matchingSessions`, unscoped.
    let allTurns: [ActivityTurn]
    /// Deduplicated turns of `sessions`, scoped to the period.
    let turns: [ActivityTurn]
    /// Canonical Core result. Primary metrics share one receipt population,
    /// exact time window, unit definitions and completeness markers.
    let accounting: ActivityAccounting.Report
    let projects: [String]
    let projectLabels: [String: String]
    let assignments: [String: AgentPersonaCatalog.Assignment]

    static func build(overview: ActivityOverview, key: Key,
                      assignments: [String: AgentPersonaCatalog.Assignment]? = nil) -> ReportScope {
        let query = key.query
        // Ownership needs the complete snapshot. Filtering an ancestor out by
        // project/search first must not turn its copied records into child work.
        // These projections only feed reporting; raw inspector/audit data stays
        // untouched in overview.
        let owned = ActivityAnalytics.ownedTurnsBySession(in: overview.sessions)
        var projectedByID: [String: ActivitySession] = [:]
        for session in overview.sessions {
            if let prior = projectedByID[session.id],
               session.observedAt < prior.observedAt || (session.observedAt == prior.observedAt && session.updatedAt < prior.updatedAt) { continue }
            var projected = session
            projected.turns = owned[session.id] ?? []
            projectedByID[session.id] = projected
        }
        let projected = Array(projectedByID.values)
        let matching = projected.filter { session in
            (key.provider == "all" || session.provider.rawValue == key.provider)
                && (key.project == "all" || session.projectPath == key.project ||
                    (key.project == ActivityAccountingQuery.unattributedProjectID && session.projectPath == nil))
                && (query.isEmpty || [session.title, session.goal?.objective ?? "", session.projectPath ?? "", session.models.joined(separator: " "),
                                      session.models.map(ModelNaming.display).joined(separator: " "), session.nativeID]
                    .joined(separator: " ").localizedCaseInsensitiveContains(query))
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
        let inPeriod = matching.filter { session in
            guard let cutoff = key.cutoff else { return true }
            if session.goal?.isOpen == true { return true }
            if session.updatedAt >= cutoff && session.updatedAt <= key.now { return true }
            return session.turns.contains { turn in
                if turn.modelSteps?.contains(where: { step in
                    step.timestamp.map { $0 >= cutoff && $0 < key.now } ?? false
                }) == true { return true }
                if let start = turn.startedAt, let end = turn.completedAt, end >= start {
                    return start < key.now && end > cutoff
                }
                return ActivityAnalytics.timestamp(turn).map { $0 >= cutoff && $0 <= key.now } ?? false
            }
        }
        let paths = Set(projected.compactMap(\.projectPath))
        return ReportScope(
            matchingSessions: matching,
            sessions: inPeriod,
            allTurns: ActivityMetrics.uniqueTurns(matching),
            turns: ActivityDisplay.turns(inPeriod, after: key.cutoff, before: key.now),
            accounting: ActivityAccounting.build(overview: overview, sessionIDs: Set(matching.map(\.id)), from: key.cutoff, to: key.now),
            projects: paths.sorted(),
            projectLabels: labels(for: paths),
            assignments: assignments ?? PersonaDirectory.assignments(for: overview)
        )
    }

    /// Top-level sessions in their given order with sub-agents keyed by parent
    /// ID. Parents are referenced by app ID or provider-native ID. A sub-agent
    /// whose parent isn't in the list stays top-level, so a filter never hides
    /// it. Duplicate observations resolve to the newest session. Ambiguous
    /// native references stay top-level; cycles lose one deterministic edge.
    /// The pinned root leads.
    static func sessionTree(_ sessions: [ActivitySession], pinnedID: String?) -> (roots: [ActivitySession], children: [String: [ActivitySession]]) {
        var orderedIDs: [String] = []
        var byID: [String: ActivitySession] = [:]
        for session in sessions {
            if let prior = byID[session.id] {
                if session.observedAt > prior.observedAt || (session.observedAt == prior.observedAt && session.updatedAt >= prior.updatedAt) {
                    byID[session.id] = session
                }
            } else {
                orderedIDs.append(session.id)
                byID[session.id] = session
            }
        }
        let parents = ActivityAnalytics.sessionParents(in: Array(byID.values))
        var children: [String: [ActivitySession]] = [:]
        var roots: [ActivitySession] = []
        for id in orderedIDs {
            guard let session = byID[id] else { continue }
            if let parent = parents[id] {
                children[parent, default: []].append(session)
            } else {
                roots.append(session)
            }
        }
        if let pinnedID, let index = roots.firstIndex(where: { $0.id == pinnedID }) {
            roots.insert(roots.remove(at: index), at: 0)
        }
        return (roots, children)
    }

    /// Folder names, with the parent folder added when two projects share one.
    static func labels(for paths: Set<String>) -> [String: String] {
        let names = Dictionary(grouping: paths) { URL(fileURLWithPath: $0).lastPathComponent }
        var labels: [String: String] = [:]
        for (name, group) in names {
            for path in group {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
                labels[path] = group.count > 1 ? "\(name) · \(parent)" : name
            }
        }
        return labels
    }
}

/// Immutable preparation result. Only this value crosses from the worker to
/// the UI; the UI's small presentation memo is never shared with that worker.
struct PreparedReportScope: @unchecked Sendable {
    struct Key: Equatable, Sendable {
        var scope: ReportScope.Key
        var chartCutoff: Date
        var hourly: Bool
        var period: ReportPeriod
        var includeCreditEstimates = false

        /// A newer source revision/window may hydrate the same view, including
        /// crossing midnight. A user-selected filter or period must not show
        /// the old view under a new label.
        func hasSameSelection(as other: Self) -> Bool {
            period == other.period && hourly == other.hourly &&
                scope.provider == other.scope.provider && scope.project == other.scope.project &&
                scope.query == other.scope.query
        }
    }

    let key: Key
    let overview: ActivityOverview
    let scope: ReportScope
    let chartAccounting: ActivityAccounting.Report
    let chartSeries: ActivityAccounting.Series
    let bySession: [String: ActivityAccounting.Report]
    let byProject: [String: ActivityAccounting.Report]
    let weekdayHour: [[Int]]?
    let overnightShare: Double?
    let liveWork: LiveWork.Summary
    let roster: TeamRosterView.Roster
    let emptyAccounting: ActivityAccounting.Report
    /// Recent starts, finishes and new sub-agents in this view (metadata only).
    var liveFeed: [LiveFeed.Event] = []
    /// Commits from scanned repositories, linked to this view's sessions.
    var shipped: ShippedCodeReport.Result = .empty
    var creditEstimates: CodexCreditEstimates.Result? = nil
    /// Observed model steps per chart bucket for each project (empty key:
    /// no folder recorded) and each session, dated on the chart series' own
    /// buckets.
    var projectTrends: [String: Trend] = [:]
    var sessionTrends: [String: Trend] = [:]

    struct Trend: Sendable {
        /// nil where a bucket has records but no observed steps.
        var values: [Double?]
        /// Buckets without any dated records: not confirmed zero.
        var empty: Set<Int>

        init(_ value: ActivityAccounting.BucketSteps) {
            values = value.steps.map { $0 > 0 ? Double($0) : nil }
            empty = Set(value.hasRecords.indices.filter { !value.hasRecords[$0] })
        }
    }

    static func build(overview: ActivityOverview, key: Key,
                      assignments: [String: AgentPersonaCatalog.Assignment]? = nil) -> PreparedReportScope {
        let scope = ReportScope.build(overview: overview, key: key.scope, assignments: assignments)
        let accounting = scope.accounting
        let chart = key.chartCutoff == key.scope.cutoff ? accounting : ActivityAccounting.build(
            overview: overview, sessionIDs: Set(scope.matchingSessions.map(\.id)), from: key.chartCutoff, to: key.scope.now)
        let bySession = accounting.bySession()
        let tree = ReportScope.sessionTree(scope.sessions, pinnedID: overview.pinnedSessionID)
        let live = LiveWork.summary(roots: tree.roots, children: tree.children, now: key.scope.now,
            ownershipContext: overview.sessions, accounting: accounting, accountingBySession: bySession)
        let empty = accounting.projected(sessionIDs: [])
        // Keep side chats and metadata-only sessions discoverable under their
        // native identity. Only canonical period evidence contributes metrics;
        // sessions outside the period use compact explanatory rows, not zeros.
        let roster = TeamRosterView.Roster.build(sessions: scope.matchingSessions, overview: overview,
            assignments: scope.assignments, now: key.scope.now, accounting: accounting, bySession: bySession)
        let chartSeries = chart.series(granularity: key.hourly ? .hour : .day)
        return PreparedReportScope(key: key, overview: overview, scope: scope, chartAccounting: chart,
            chartSeries: chartSeries, bySession: bySession,
            byProject: accounting.byProject(), weekdayHour: key.hourly ? nil : chart.weekdayHourModelSteps(),
            overnightShare: key.hourly ? chart.overnightModelStepShare() : nil,
            liveWork: live, roster: roster, emptyAccounting: empty,
            liveFeed: LiveFeed.events(sessions: scope.sessions, now: key.scope.now),
            shipped: ShippedCodeReport.build(.init(sessions: scope.sessions, repositories: overview.repositories, from: key.scope.cutoff, to: key.scope.now,
                                                   tokensBySession: bySession.compactMapValues { $0.totals.usage.tokensKnown },
                                                   outputTokensBySession: bySession.compactMapValues { $0.totals.usage.outputKnown })),
            creditEstimates: key.includeCreditEstimates ? CodexCreditEstimates.buildForDisplay(report: accounting) : nil,
            projectTrends: PerfTrace.measure("projectTrends") { ActivityAccounting.modelStepsByProject(chart, series: chartSeries).mapValues(Trend.init) },
            sessionTrends: PerfTrace.measure("sessionTrends") { ActivityAccounting.modelStepsBySession(chart, series: chartSeries).mapValues(Trend.init) })
    }
}

/// One active worker and one replaceable pending snapshot, even while the
/// window hides/reopens or filters change faster than preparation can finish.
/// Recently prepared views for other selections (Credits' Codex-only scope,
/// another filter) are kept briefly, so going back to them is instant.
@MainActor final class ReportScopePreparation: ObservableObject {
    typealias Builder = @Sendable (ActivityOverview, PreparedReportScope.Key) async -> PreparedReportScope
    @Published private(set) var prepared: PreparedReportScope?
    @Published private(set) var isPreparing = false
    private var desiredKey: PreparedReportScope.Key?
    private var activeKey: PreparedReportScope.Key?
    private var pending: (ActivityOverview, PreparedReportScope.Key)?
    private var worker: Task<Void, Never>?
    private let build: Builder
    /// Newest first, one per selection.
    private(set) var recent: [PreparedReportScope] = []
    static let recentLimit = 4
    /// Views of older snapshots than this are dropped rather than kept as
    /// stale stand-ins; each one holds a full snapshot.
    static let recentMaximumAge: TimeInterval = 15 * 60

    init(build: @escaping Builder = { overview, key in
        await Task.detached(priority: .utility) {
            PerfTrace.measure("prepare", detail: "\(overview.sessions.count) sessions") { PreparedReportScope.build(overview: overview, key: key) }
        }.value
    }) { self.build = build }

    func request(overview: ActivityOverview, key: PreparedReportScope.Key) {
        desiredKey = key
        if prepared?.key == key { isPreparing = false; return }
        if let exact = recent.first(where: { $0.key == key }) {
            prepared = exact
            pending = nil
            isPreparing = false
            return
        }
        if prepared?.key.hasSameSelection(as: key) != true {
            // Show this selection's last view while its newer one is built.
            prepared = recent.first { $0.key.hasSameSelection(as: key) }
        }
        isPreparing = true
        if activeKey != key { pending = (overview, key) }
        else { pending = nil }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            await self.drain()
        }
    }

    /// Stale-while-revalidate is safe only for the same user-selected view.
    /// Callers use the returned snapshot for ALL displayed facts and dates.
    func displayed(for key: PreparedReportScope.Key?) -> PreparedReportScope? {
        guard let key else { return nil }
        if let prepared, prepared.key.hasSameSelection(as: key) { return prepared }
        // A page change renders before its request runs; a kept view of the
        // new selection paints in that first frame instead of a loading state.
        return recent.first { $0.key.hasSameSelection(as: key) }
    }

    /// Stops wanting a view (another page, a hidden window) but keeps what
    /// was prepared, so returning shows it at once.
    func suspend() {
        desiredKey = nil
        pending = nil
        isPreparing = false
    }

    func deactivate() {
        suspend()
        prepared = nil
        recent = []
        // Do not cancel and replace an uncancellable CPU-bound worker. Its
        // result will be discarded, then the latest reopened request can run.
    }

    private func remember(_ value: PreparedReportScope) {
        recent.removeAll { $0.key.hasSameSelection(as: value.key) }
        recent.insert(value, at: 0)
        let newest = recent.map(\.key.scope.now).max() ?? value.key.scope.now
        recent = Array(recent.filter { newest.timeIntervalSince($0.key.scope.now) <= Self.recentMaximumAge }.prefix(Self.recentLimit))
    }

    func waitUntilIdle() async { await worker?.value }

    private func drain() async {
        while let (overview, key) = pending {
            pending = nil
            activeKey = key
            let value = await build(overview, key)
            activeKey = nil
            if recent.first(where: { $0.key.hasSameSelection(as: key) }).map({ key.scope.snapshotRevision >= $0.key.scope.snapshotRevision }) ?? true {
                remember(value)
            }
            // Publish complete same-selection revisions monotonically, even
            // while a still-newer source revision is pending. Otherwise a busy
            // live stream can starve the view forever. Metadata stays frozen
            // to this value and the footer continues to show Updating.
            if let desiredKey, desiredKey.hasSameSelection(as: key),
               prepared.map({ key.scope.snapshotRevision >= $0.key.scope.snapshotRevision }) ?? true {
                prepared = value
            }
            isPreparing = desiredKey.map { prepared?.key != $0 } ?? false
        }
        worker = nil
    }
}

/// Holds the current scope plus values derived from it, and those of the
/// last few scopes, so going back to a page with other filters (Credits'
/// Codex-only view) reuses its values. Lives in `@State`, so reading it
/// during a redraw never publishes a change.
final class ReportScopeCache {
    static let maximumDerivedValues = 64
    static let maximumScopes = 4
    private struct Entry {
        var key: ReportScope.Key
        var scope: ReportScope
        var derived: [String: Any] = [:]
    }
    /// Newest first; the first entry is the current scope.
    private var entries: [Entry] = []
    private var derived: [String: Any] {
        get { entries.first?.derived ?? [:] }
        set { if !entries.isEmpty { entries[0].derived = newValue } }
    }

    var derivedValueCount: Int { derived.count }

    func reset() {
        entries.removeAll(keepingCapacity: false)
    }

    func scope(for key: ReportScope.Key, build: () -> ReportScope) -> ReportScope {
        if let first = entries.first, first.key == key { return first.scope }
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries.insert(entries.remove(at: index), at: 0)
            return entries[0].scope
        }
        let value = build()
        // A newer snapshot of the same filters replaces the older one.
        entries.removeAll { Self.sameSelection($0.key, key) }
        entries.insert(Entry(key: key, scope: value), at: 0)
        if entries.count > Self.maximumScopes { entries.removeLast(entries.count - Self.maximumScopes) }
        return value
    }

    static func sameSelection(_ lhs: ReportScope.Key, _ rhs: ReportScope.Key) -> Bool {
        // Whole days of the window: steady while the clock moves within a day.
        func span(_ key: ReportScope.Key) -> Int { key.cutoff.map { Int((key.now.timeIntervalSince($0) / 86_400).rounded(.down)) } ?? -1 }
        return lhs.provider == rhs.provider && lhs.project == rhs.project && lhs.query == rhs.query && span(lhs) == span(rhs)
    }

    /// A value that also depends on something outside the scope (a clock, the
    /// quota state): one entry per name, rebuilt when its tag changes, so a
    /// changing tag never fills the cache and wipes every other value.
    func value<T>(_ name: String, tag: String, build: () -> T) -> T {
        if let entry = derived[name] as? (tag: String, value: T), entry.tag == tag { return entry.value }
        let value = build()
        if derived.count >= Self.maximumDerivedValues { derived.removeAll(keepingCapacity: false) }
        derived[name] = (tag: tag, value: value)
        return value
    }

    /// A value computed from the current scope, rebuilt whenever the scope is.
    func value<T>(_ name: String, build: () -> T) -> T {
        // Check presence first: a missing entry would otherwise cast to a
        // nil Optional and a memoised optional would never be built.
        if let entry = derived[name], let cached = entry as? T { return cached }
        let value = build()
        // Dynamic evidence keys must not retain one graph for every reading.
        if derived.count >= Self.maximumDerivedValues { derived.removeAll(keepingCapacity: false) }
        derived[name] = value
        return value
    }
}
