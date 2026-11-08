import Foundation

/// Pure, deterministic aggregations behind the activity charts. Every series
/// is a lower bound built only from receipts that carry the needed field.
/// Open intervals are never extended; measured* values distinguish missing
/// evidence from the zero-filled coordinates used to lay out empty chart bins.
public enum ActivityAnalytics {
    /// Days, hours and report windows follow this Mac's own time zone.
    /// Settable so tests can pin a zone and stay independent of the host.
    public static var reportingTimeZone = TimeZone.current

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// The moment a turn is attributed to: completion when known, else start.
    public static func timestamp(_ turn: ActivityTurn) -> Date? { turn.completedAt ?? turn.startedAt }

    /// Shared scope for all reporting surfaces. An undated receipt cannot be
    /// placed in a time-bounded view; retain it only for an unbounded query.
    public static func scopedTurns(_ turns: [ActivityTurn], from: Date?, to: Date?) -> [ActivityTurn] {
        uniqueTurns(turns).filter { turn in
            guard let stamp = timestamp(turn) else { return from == nil && to == nil }
            return (from.map { stamp >= $0 } ?? true) && (to.map { stamp < $0 } ?? true)
        }
    }

    // MARK: Provider attribution

    /// Maps each unique turn ID to the provider of the newest session that
    /// carried it, matching `ActivityMetrics.uniqueTurns`.
    public static func providers(_ sessions: [ActivitySession]) -> [String: AgentName] {
        var result: [String: AgentName] = [:]
        for session in sessions.sorted(by: { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt }) {
            for turn in session.turns { result[turn.id] = session.provider }
        }
        return result
    }

    // MARK: Daily series

    public struct DailyPoint: Equatable, Identifiable, Sendable {
        public var day: Date
        public var tokens: Int
        public var outputTokens: Int
        public var turns: Int
        public var activeSeconds: Double
        public var tokenReceipts: Int = 0
        public var outputTokenReceipts: Int = 0
        public var partialTokenReceipts: Int = 0
        public var partialOutputTokenReceipts: Int = 0
        public var closedIntervalReceipts: Int = 0
        public var tokenOverflow: Bool = false
        public var outputTokenOverflow: Bool = false
        public var measuredTokens: Int? { tokenReceipts > 0 && !tokenOverflow ? tokens : nil }
        public var measuredOutputTokens: Int? { outputTokenReceipts > 0 && !outputTokenOverflow ? outputTokens : nil }
        public var measuredActiveSeconds: Double? { closedIntervalReceipts > 0 ? activeSeconds : nil }
        public var tokenCoverage: Double? { turns > 0 ? Double(tokenReceipts) / Double(turns) : nil }
        public var outputTokenCoverage: Double? { turns > 0 ? Double(outputTokenReceipts) / Double(turns) : nil }
        public var id: Date { day }
    }

    /// One point per calendar day in `[start, end]`, including empty days so
    /// sparklines keep their shape. Active seconds use closed intervals only,
    /// clipped to each day and `end`, with overlaps counted once. Raw numeric
    /// fields are zero-filled chart coordinates; measured* distinguishes an
    /// actual zero receipt from missing evidence. The end boundary is exclusive.
    public static func daily(
        _ turns: [ActivityTurn],
        days: Int,
        endingAt end: Date = Date(),
        startingAt start: Date? = nil,
        timeZone: TimeZone = reportingTimeZone
    ) -> [DailyPoint] {
        let calendar = calendar(timeZone)
        let lastDay = calendar.startOfDay(for: end)
        guard days > 0, let firstDay = calendar.date(byAdding: .day, value: -(days - 1), to: lastDay) else { return [] }
        let lowerBound = max(firstDay, start ?? firstDay)
        guard validRange(from: lowerBound, to: end) else { return [] }
        var points: [Date: DailyPoint] = [:]
        var dayStarts: [Date] = []
        for offset in 0 ..< days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
            dayStarts.append(day)
            points[day] = DailyPoint(day: day, tokens: 0, outputTokens: 0, turns: 0, activeSeconds: 0)
        }
        let turns = uniqueTurns(turns)
        for turn in turns {
            guard let stamp = timestamp(turn), stamp >= lowerBound, stamp < end else { continue }
            let day = calendar.startOfDay(for: stamp)
            guard var point = points[day] else { continue }
            point.turns += 1
            if let tokens = nonnegative(turn.usage.total) {
                point.tokenOverflow = point.tokenOverflow || point.tokens.addingReportingOverflow(tokens).overflow
                point.tokens = adding(point.tokens, tokens)
                point.tokenReceipts += 1
                if turn.usageIsPartial == true { point.partialTokenReceipts += 1 }
            }
            if let output = nonnegative(turn.usage.output) {
                point.outputTokenOverflow = point.outputTokenOverflow || point.outputTokens.addingReportingOverflow(output).overflow
                point.outputTokens = adding(point.outputTokens, output)
                point.outputTokenReceipts += 1
                if turn.usageIsPartial == true { point.partialOutputTokenReceipts += 1 }
            }
            points[day] = point
        }
        for day in dayStarts {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
            let intervals = closedIntervals(turns, from: max(day, lowerBound), to: min(next, end))
            points[day]?.activeSeconds = duration(merged(intervals))
            points[day]?.closedIntervalReceipts = intervals.count
        }
        return dayStarts.compactMap { points[$0] }
    }

    /// Calendar bins clipped to the exact half-open window. Rolling windows
    /// commonly have two partial edge days: seven elapsed days can span eight
    /// calendar dates. No receipt before `start` is pulled into the first bin.
    public static func daily(
        _ turns: [ActivityTurn],
        from start: Date,
        to end: Date,
        timeZone: TimeZone = reportingTimeZone
    ) -> [DailyPoint] {
        guard validRange(from: start, to: end) else { return [] }
        let calendar = calendar(timeZone)
        let firstDay = calendar.startOfDay(for: start)
        let lastDay = calendar.startOfDay(for: end)
        guard let distance = calendar.dateComponents([.day], from: firstDay, to: lastDay).day,
              distance >= 0, distance < 36_600 else { return [] }
        // daily(days:) intentionally includes today's coordinate even when
        // end is midnight. Remove that empty exclusive-boundary date here.
        return daily(turns, days: distance + 1, endingAt: end, startingAt: start, timeZone: timeZone)
            .filter { $0.day < end }
    }

    /// Bucket size for trend charts. Short windows read best hour by hour.
    public enum Granularity: Sendable {
        case hour, day
    }

    /// One point per clock hour from the hour containing `start` up to `end`,
    /// with the same clipping, de-duplication and measured/missing rules as
    /// `daily`. `day` holds each bucket's start. The end boundary is exclusive.
    public static func hourly(
        _ turns: [ActivityTurn],
        from start: Date,
        to end: Date,
        timeZone: TimeZone = reportingTimeZone
    ) -> [DailyPoint] {
        guard validRange(from: start, to: end), let first = calendar(timeZone).dateInterval(of: .hour, for: start)?.start else { return [] }
        let calendar = calendar(timeZone)
        var bucketStarts: [Date] = []
        var cursor = first
        // A year of hours is far beyond any chart; the cap keeps a bad range cheap.
        while cursor < end, bucketStarts.count < 24 * 366 {
            bucketStarts.append(cursor)
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor), next > cursor else { return [] }
            cursor = next
        }
        // A partial prefix would silently disagree with the period's token
        // totals. An unsupported range is unavailable, never a truncated chart.
        guard cursor >= end else { return [] }
        var points = Dictionary(uniqueKeysWithValues: bucketStarts.map { ($0, DailyPoint(day: $0, tokens: 0, outputTokens: 0, turns: 0, activeSeconds: 0)) })
        let turns = uniqueTurns(turns)
        for turn in turns {
            guard let stamp = timestamp(turn), stamp >= start, stamp < end,
                  let bucket = calendar.dateInterval(of: .hour, for: stamp)?.start, var point = points[bucket] else { continue }
            point.turns += 1
            if let tokens = nonnegative(turn.usage.total) {
                point.tokenOverflow = point.tokenOverflow || point.tokens.addingReportingOverflow(tokens).overflow
                point.tokens = adding(point.tokens, tokens)
                point.tokenReceipts += 1
                if turn.usageIsPartial == true { point.partialTokenReceipts += 1 }
            }
            if let output = nonnegative(turn.usage.output) {
                point.outputTokenOverflow = point.outputTokenOverflow || point.outputTokens.addingReportingOverflow(output).overflow
                point.outputTokens = adding(point.outputTokens, output)
                point.outputTokenReceipts += 1
                if turn.usageIsPartial == true { point.partialOutputTokenReceipts += 1 }
            }
            points[bucket] = point
        }
        // Clip intervals once to the whole window, then walk the buckets.
        let windowIntervals = merged(closedIntervals(turns, from: start, to: end))
        let receipts = closedIntervals(turns, from: start, to: end)
        for bucket in bucketStarts {
            guard let next = calendar.date(byAdding: .hour, value: 1, to: bucket) else { continue }
            let lower = max(bucket, start), upper = min(next, end)
            let seconds = windowIntervals.reduce(0.0) { total, interval in
                let a = max(interval.start, lower), b = min(interval.end, upper)
                return b > a ? total + b.timeIntervalSince(a) : total
            }
            points[bucket]?.activeSeconds = seconds
            points[bucket]?.closedIntervalReceipts = receipts.filter { $0.start < upper && $0.end > lower || ($0.start == $0.end && $0.start >= lower && $0.start < upper) }.count
        }
        return bucketStarts.compactMap { points[$0] }
    }

    /// Hourly or daily points for a chart, sharing every other rule.
    public static func series(
        _ turns: [ActivityTurn],
        from start: Date,
        to end: Date,
        granularity: Granularity,
        timeZone: TimeZone = reportingTimeZone
    ) -> [DailyPoint] {
        switch granularity {
        case .hour: return hourly(turns, from: start, to: end, timeZone: timeZone)
        case .day: return daily(turns, from: start, to: end, timeZone: timeZone)
        }
    }

    public struct ProviderDay: Equatable, Identifiable, Sendable {
        public var day: Date
        public var provider: AgentName
        public var tokens: Int?
        public var turns: Int
        public var tokenReceipts: Int
        public var partialTokenReceipts: Int
        public var id: String { "\(provider.rawValue):\(day.timeIntervalSince1970)" }
        public var tokenCoverage: Double? { turns > 0 ? Double(tokenReceipts) / Double(turns) : nil }
        public var isPartial: Bool { tokenReceipts < turns || partialTokenReceipts > 0 }
    }

    public struct DailyTokenBreakdown: Equatable, Sendable {
        public var days: [DailyPoint]
        public var rows: [ProviderDay]
        /// Same exact scope and de-duplication as the overview KPI. Consumers
        /// must use this total, not sum a compactMap that hides overflow rows.
        public var period: Period
    }

    /// One aggregation for the KPI, daily trend, provider stacks and coverage.
    /// Every observed provider gets every calendar coordinate. Unknown usage
    /// stays nil; an explicit provider-reported zero remains a measured zero.
    public static func dailyTokenBreakdown(
        _ turns: [ActivityTurn],
        providers: [String: AgentName],
        from start: Date,
        to end: Date,
        granularity: Granularity = .day,
        timeZone: TimeZone = reportingTimeZone
    ) -> DailyTokenBreakdown {
        let turns = uniqueTurns(turns)
        let days = series(turns, from: start, to: end, granularity: granularity, timeZone: timeZone)
        let scoped = scopedTurns(turns, from: start, to: end)
        let grouped = Dictionary(grouping: scoped, by: { providers[$0.id] ?? .none })
        let rows = grouped.keys.sorted { $0.rawValue < $1.rawValue }.flatMap { provider in
            series(grouped[provider] ?? [], from: start, to: end, granularity: granularity, timeZone: timeZone).map { point in
                ProviderDay(day: point.day, provider: provider, tokens: point.measuredTokens,
                            turns: point.turns, tokenReceipts: point.tokenReceipts,
                            partialTokenReceipts: point.partialTokenReceipts)
            }
        }
        return DailyTokenBreakdown(days: days, rows: rows, period: period(turns, sessions: 0, from: start, to: end))
    }

    // MARK: Sparkline evidence

    public struct TrendPoint: Equatable, Identifiable, Sendable {
        public var index: Int
        public var value: Double?
        /// Adjacent measured coordinates share a segment. A missing coordinate
        /// breaks the line, but remains present as an explicit missing marker.
        public var segment: Int
        public var id: Int { index }
    }

    public static func trend(_ values: [Double?]) -> [TrendPoint] {
        var segment = 0
        return values.enumerated().map { index, raw in
            guard let value = raw, value.isFinite, value >= 0 else {
                segment += 1
                return TrendPoint(index: index, value: nil, segment: segment)
            }
            return TrendPoint(index: index, value: value, segment: segment)
        }
    }

    // MARK: Heatmap

    public struct HeatCell: Equatable, Identifiable, Sendable {
        /// 0 = oldest day in the window.
        public var dayIndex: Int
        public var day: Date
        public var hour: Int
        public var turns: Int
        public var tokens: Int
        public var tokenReceipts: Int = 0
        public var tokenOverflow: Bool = false
        public var measuredTokens: Int? { tokenReceipts > 0 && !tokenOverflow ? tokens : nil }
        public var id: String { "\(dayIndex)-\(hour)" }
    }

    /// Day × hour grid of turn counts and tokens, every cell present.
    public static func heatmap(
        _ turns: [ActivityTurn],
        days: Int,
        endingAt end: Date = Date(),
        timeZone: TimeZone = reportingTimeZone
    ) -> [HeatCell] {
        let calendar = calendar(timeZone)
        let lastDay = calendar.startOfDay(for: end)
        guard days > 0, let firstDay = calendar.date(byAdding: .day, value: -(days - 1), to: lastDay) else { return [] }
        var grid = [[(turns: Int, tokens: Int, receipts: Int, overflow: Bool)]](repeating: Array(repeating: (0, 0, 0, false), count: 24), count: days)
        for turn in uniqueTurns(turns) {
            guard let stamp = timestamp(turn), stamp >= firstDay, stamp < end else { continue }
            let day = calendar.startOfDay(for: stamp)
            guard let index = calendar.dateComponents([.day], from: firstDay, to: day).day,
                  index >= 0, index < days else { continue }
            let hour = calendar.component(.hour, from: stamp)
            grid[index][hour].turns += 1
            if let tokens = nonnegative(turn.usage.total) {
                grid[index][hour].overflow = grid[index][hour].overflow || grid[index][hour].tokens.addingReportingOverflow(tokens).overflow
                grid[index][hour].tokens = adding(grid[index][hour].tokens, tokens)
                grid[index][hour].receipts += 1
            }
        }
        var cells: [HeatCell] = []
        for index in 0 ..< days {
            let day = calendar.date(byAdding: .day, value: index, to: firstDay) ?? firstDay
            for hour in 0 ..< 24 {
                cells.append(HeatCell(dayIndex: index, day: day, hour: hour, turns: grid[index][hour].turns, tokens: grid[index][hour].tokens, tokenReceipts: grid[index][hour].receipts, tokenOverflow: grid[index][hour].overflow))
            }
        }
        return cells
    }

    // MARK: Composition

    public struct Share: Equatable, Identifiable, Sendable {
        public var name: String
        public var value: Int
        /// `value` remains a safe layout coordinate when a source aggregate
        /// overflows, but is no longer an authoritative count.
        public var overflow: Bool = false
        public var id: String { name }
    }

    public struct CategoryBarScale: Equatable, Sendable {
        /// Nil when no counts were supplied, a count was malformed, or the
        /// sum cannot be represented. Never use a saturated sum as a share.
        public var total: Int?
        /// Independent of display order; the catch-all Other sorts last even
        /// when it is the largest category.
        public var maximum: Int

        public func barFraction(for value: Int) -> Double? {
            guard value >= 0, maximum > 0 else { return nil }
            return min(1, max(0, Double(value) / Double(maximum)))
        }

        public func shareFraction(for value: Int) -> Double? {
            guard value >= 0, let total, total > 0 else { return nil }
            return min(1, max(0, Double(value) / Double(total)))
        }
    }

    public static func categoryBarScale(_ categories: [Share]) -> CategoryBarScale {
        let values = categories.map(\.value)
        let total = categories.contains(where: \.overflow) || values.contains(where: { $0 < 0 })
            ? nil : measuredTotal(values.map(Optional.some))
        return CategoryBarScale(total: total, maximum: values.filter { $0 >= 0 }.max() ?? 0)
    }

    /// Observed tool categories, largest first. Categories describe tool use,
    /// not token allocation.
    public static func categoryMix(_ turns: [ActivityTurn]) -> [Share] {
        var totals: [String: Int] = [:]
        var overflowed = Set<String>()
        for turn in uniqueTurns(turns) {
            for (name, count) in turn.categories where count > 0 {
                let category = displayCategory(name)
                if totals[category, default: 0].addingReportingOverflow(count).overflow {
                    overflowed.insert(category)
                }
                totals[category] = adding(totals[category, default: 0], count)
            }
        }
        // "Other" is a catch-all, so it always trails the named categories.
        return totals.map { Share(name: $0.key, value: $0.value, overflow: overflowed.contains($0.key)) }
            .sorted { lhs, rhs in
                if (lhs.name == "Other") != (rhs.name == "Other") { return rhs.name == "Other" }
                return lhs.value == rhs.value ? lhs.name < rhs.name : lhs.value > rhs.value
            }
    }

    static func displayCategory(_ raw: String) -> String {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "", "other tools", "other": return "Other"
        default: return normalized.prefix(1).uppercased() + normalized.dropFirst()
        }
    }

    public struct ModelShare: Equatable, Identifiable, Sendable {
        public var model: String
        public var provider: AgentName
        public var turns: Int
        public var tokens: Int
        public var tokenReceipts: Int = 0
        public var tokenOverflow: Bool = false
        public var measuredTokens: Int? { tokenReceipts > 0 && !tokenOverflow ? tokens : nil }
        public var id: String { "\(provider.rawValue):\(model)" }
    }

    /// Known-model turns and tokens. Turns without a model are left out
    /// rather than shown as a fake model.
    public static func modelMix(_ turns: [ActivityTurn], providers: [String: AgentName]) -> [ModelShare] {
        var totals: [String: ModelShare] = [:]
        for turn in uniqueTurns(turns) {
            guard let model = turn.model?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else { continue }
            let provider = providers[turn.id] ?? .none
            let key = "\(provider.rawValue):\(model)"
            var share = totals[key] ?? ModelShare(model: model, provider: provider, turns: 0, tokens: 0)
            share.turns += 1
            if let tokens = nonnegative(turn.usage.total) {
                share.tokenOverflow = share.tokenOverflow || share.tokens.addingReportingOverflow(tokens).overflow
                share.tokens = adding(share.tokens, tokens)
                share.tokenReceipts += 1
            }
            totals[key] = share
        }
        return totals.values.sorted { $0.turns == $1.turns ? $0.id < $1.id : $0.turns > $1.turns }
    }

    // MARK: Goal swimlane

    public struct Interval: Equatable, Sendable {
        public var start: Date
        public var end: Date
    }

    public struct Lane: Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var model: String?
        public var provider: AgentName
        public var isParent: Bool
        public var intervals: [Interval]
        /// Starts with no recorded end: shown as markers, never as bars.
        public var openStarts: [Date]
        public var lastActivity: Date?
        public var busySeconds: Double
        /// One clipped bar per recorded turn, for display only. Timing and
        /// concurrency always use the merged `intervals`.
        public var segments: [Segment] = []
        /// Turns attributed to this lane with a timestamp inside the range.
        public var turnCount: Int = 0
    }

    public struct Segment: Equatable, Sendable {
        public var turnID: String
        public var start: Date
        public var end: Date
        /// Dominant observed tool category of the turn, display-cased.
        public var category: String?
        /// Zero-filled legacy coordinate. Use measuredToolCalls in labels so
        /// an absent tool receipt is not presented as an observed zero.
        public var toolCalls: Int
        public var measuredToolCalls: Int? = nil
    }

    static func dominantCategory(_ turn: ActivityTurn) -> String? {
        var categories: [String: Int] = [:]
        for (name, count) in turn.categories where count > 0 {
            let name = displayCategory(name)
            categories[name] = adding(categories[name, default: 0], count)
        }
        let ranked = categories
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        return ranked.first?.key
    }

    /// Transitive descendants in deterministic breadth-first order. Native
    /// parent IDs are only resolved inside the same provider namespace; stale
    /// duplicate snapshots, self-links and cycles cannot duplicate a session.
    public static func descendants(of parent: ActivitySession, in sessions: [ActivitySession]) -> [ActivitySession] {
        var byID: [String: ActivitySession] = [:]
        for session in sessions.sorted(by: { $0.observedAt == $1.observedAt ? $0.id < $1.id : $0.observedAt < $1.observedAt })
            where session.provider == parent.provider && session.id != parent.id {
            byID[session.id] = session
        }
        let candidates = byID.values.sorted { $0.id < $1.id }
        var seen: Set<String> = [parent.id]
        var queue = [parent]
        var cursor = 0
        var result: [ActivitySession] = []
        while cursor < queue.count {
            let ancestor = queue[cursor]
            cursor += 1
            for child in candidates where !seen.contains(child.id) {
                guard let reference = child.parentSessionID, !reference.isEmpty,
                      reference == ancestor.id || (!ancestor.nativeID.isEmpty && reference == ancestor.nativeID) else { continue }
                seen.insert(child.id)
                queue.append(child)
                result.append(child)
            }
        }
        return result
    }

    /// Work attributed to a session, excluding turn IDs also carried by an
    /// observed ancestor. Forks retain their copied receipts in the audit store;
    /// those copies must not become new child work in roster cards or roles.
    /// Pass the full snapshot so filtering an ancestor out of the UI does not
    /// change ownership. Unknown/missing ancestors are never invented.
    public static func ownedTurns(for session: ActivitySession, in sessions: [ActivitySession]) -> [ActivityTurn] {
        ownedTurnsBySession(in: sessions + [session])[session.id] ?? []
    }

    /// Known parent edges in one snapshot, resolved inside each provider.
    /// Exact app IDs win over native aliases; ambiguous aliases remain roots.
    /// A malformed cycle loses its lexicographically first edge so shared
    /// receipts retain one owning ancestor instead of disappearing everywhere.
    public static func sessionParents(in sessions: [ActivitySession]) -> [String: String] {
        struct NativeReference: Hashable { var provider: AgentName; var id: String }
        var byID: [String: ActivitySession] = [:]
        for session in sessions {
            if let prior = byID[session.id],
               session.observedAt < prior.observedAt || (session.observedAt == prior.observedAt && session.updatedAt < prior.updatedAt) { continue }
            byID[session.id] = session
        }
        var nativeOwners: [NativeReference: Set<String>] = [:]
        for session in byID.values where !session.nativeID.isEmpty {
            nativeOwners[NativeReference(provider: session.provider, id: session.nativeID), default: []].insert(session.id)
        }
        var parents: [String: String] = [:]
        for session in byID.values {
            guard let reference = session.parentSessionID, !reference.isEmpty else { continue }
            if let exact = byID[reference] {
                if exact.provider == session.provider, exact.id != session.id { parents[session.id] = exact.id }
            } else if let candidates = nativeOwners[NativeReference(provider: session.provider, id: reference)],
                      candidates.count == 1, let parent = candidates.first, parent != session.id {
                parents[session.id] = parent
            }
        }
        var finished = Set<String>()
        for id in byID.keys.sorted() where !finished.contains(id) {
            var path: [String] = []
            var positions: [String: Int] = [:]
            var cursor: String? = id
            while let current = cursor, !finished.contains(current) {
                if let cycleStart = positions[current] {
                    if let anchor = path[cycleStart...].min() { parents.removeValue(forKey: anchor) }
                    break
                }
                positions[current] = path.count
                path.append(current)
                cursor = parents[current]
            }
            finished.formUnion(path)
        }
        return parents
    }

    /// Prepared form for roster, persona and lane consumers. Canonical session
    /// observations and corrected receipt values are merged once per snapshot,
    /// rather than sorting all turn history again for every visible card.
    public static func ownedTurnsBySession(in sessions: [ActivitySession]) -> [String: [ActivityTurn]] {
        let ordered = sessions.sorted {
            if $0.observedAt != $1.observedAt { return $0.observedAt < $1.observedAt }
            return $0.id == $1.id ? $0.updatedAt < $1.updatedAt : $0.id < $1.id
        }
        var byID: [String: ActivitySession] = [:]
        for candidate in ordered {
            var canonical = candidate
            if let prior = byID[candidate.id], !candidate.historyComplete {
                canonical.turns = uniqueTurns(prior.turns + candidate.turns)
            }
            byID[candidate.id] = canonical
        }
        let parents = sessionParents(in: Array(byID.values))
        let receiptsByProvider = Dictionary(grouping: ordered, by: \.provider).mapValues { providerSessions in
            Dictionary(uniqueKeysWithValues: ActivityMetrics.uniqueTurns(providerSessions).map { ($0.id, $0) })
        }
        var result: [String: [ActivityTurn]] = [:]
        for subject in byID.values {
            var inherited = Set<String>()
            var visited: Set<String> = [subject.id]
            var reference = parents[subject.id]
            while let parentID = reference, !parentID.isEmpty,
                  let ancestor = byID[parentID],
                  ancestor.provider == subject.provider,
                  visited.insert(ancestor.id).inserted {
                inherited.formUnion(ancestor.turns.map(\.id))
                reference = parents[ancestor.id]
            }
            let receipts = receiptsByProvider[subject.provider] ?? [:]
            result[subject.id] = uniqueTurns(subject.turns).compactMap { turn in
                inherited.contains(turn.id) ? nil : receipts[turn.id]
            }
        }
        return result
    }

    /// One lane for the goal and each descendant, using half-open `[from, to)`
    /// intervals. Fork-inherited turn IDs belong to the nearest observed
    /// ancestor, not to every child that copied the transcript. Overlapping
    /// turns in one agent are unioned before measuring its recorded time.
    public static func lanes(
        for parent: ActivitySession,
        in sessions: [ActivitySession],
        from: Date,
        to: Date
    ) -> [Lane] {
        guard validRange(from: from, to: to) else { return [] }
        let family = [parent] + descendants(of: parent, in: sessions)
        // The requested goal anchors this view, even if corrupt parent links
        // form a cycle back through one of its observed descendants.
        var ownershipFamily = family
        ownershipFamily[0].parentSessionID = nil
        let ownedBySession = ownedTurnsBySession(in: ownershipFamily)
        var assignedTurns = Set<String>()
        func lane(_ session: ActivitySession, isParent: Bool) -> Lane {
            let turns = (ownedBySession[session.id] ?? []).filter { turn in
                assignedTurns.insert(turn.id).inserted
            }
            let intervals = merged(closedIntervals(turns, from: from, to: to))
            var open: [Date] = []
            for turn in turns {
                guard let start = turn.startedAt, start.timeIntervalSinceReferenceDate.isFinite else { continue }
                // An invalid recorded ending is corrupt evidence, not an open turn.
                if turn.completedAt == nil, start >= from, start < to {
                    open.append(start)
                }
            }
            open.sort()
            let segments: [Segment] = turns.compactMap { turn in
                guard let start = turn.startedAt, let end = turn.completedAt, end > start,
                      start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
                      end > from, start < to else { return nil }
                let reportedCount = nonnegative(turn.toolCount)
                let categoryCount = measuredTotal(turn.categories.values.map(Optional.some))
                let measuredCount = reportedCount ?? categoryCount
                let coordinate = measuredCount ?? turn.categories.values.reduce(0) { adding($0, max(0, $1)) }
                return Segment(turnID: turn.id, start: max(start, from), end: min(end, to),
                               category: dominantCategory(turn),
                               toolCalls: coordinate, measuredToolCalls: measuredCount)
            }.sorted { $0.start == $1.start ? $0.turnID < $1.turnID : $0.start < $1.start }
            let inRangeTurns = turns.filter { timestamp($0).map { $0 >= from && $0 < to } ?? false }
            let inRange = inRangeTurns.count
            let last = (intervals.map(\.end) + open + inRangeTurns.compactMap(timestamp)).max()
            // A closed turn can overlap the window even when its completion
            // lies after it. Its observed model still describes that bar.
            let latestModel = turns.filter { turn in
                if timestamp(turn).map({ $0 >= from && $0 < to }) == true { return true }
                return !closedIntervals([turn], from: from, to: to).isEmpty
            }
                .sorted {
                    let lhs = timestamp($0) ?? .distantPast, rhs = timestamp($1) ?? .distantPast
                    return lhs == rhs ? $0.id < $1.id : lhs < rhs
                }.reversed().compactMap { $0.model?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let fallbackModel = session.models.count == 1 ? session.models.first?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return Lane(
                id: session.id,
                title: session.title,
                model: latestModel ?? fallbackModel.flatMap { $0.isEmpty ? nil : $0 },
                provider: session.provider,
                isParent: isParent,
                intervals: intervals,
                openStarts: open,
                lastActivity: last,
                busySeconds: duration(intervals),
                segments: segments,
                turnCount: inRange
            )
        }
        let parentLane = lane(parent, isParent: true)
        let childLanes = family.dropFirst().map { lane($0, isParent: false) }
            .filter { !$0.intervals.isEmpty || !$0.openStarts.isEmpty || $0.turnCount > 0 }
            .sorted {
                let lhs = $0.lastActivity ?? .distantPast, rhs = $1.lastActivity ?? .distantPast
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }
        return [parentLane] + childLanes
    }

    public struct LoadBucket: Equatable, Identifiable, Sendable {
        public var start: Date
        public var end: Date
        /// Mean number of agents working across the bucket: recorded
        /// agent-seconds divided by bucket length. Exact, not sampled.
        public var meanAgents: Double
        public var durationSeconds: TimeInterval { end.timeIntervalSince(start) }
        public var id: Date { start }
    }

    /// Mean number of distinct native sessions with recorded closed work over
    /// the exact window. Requests that overlap inside one session count once;
    /// copied ancestor receipts do not turn a fork into another working agent.
    /// This is an observed lower bound, including waits, not a live process count.
    public static func averageDistinctSessionLoad(_ sessions: [ActivitySession], from: Date, to: Date) -> Double? {
        averageDistinctSessionLoad(ownedTurns: ownedTurnsBySession(in: sessions), from: from, to: to)
    }

    /// Prepared form for a chart with many buckets. Derive ownership once per
    /// snapshot, not once for every hour on the main UI thread.
    public static func averageDistinctSessionLoad(ownedTurns: [String: [ActivityTurn]], from: Date, to: Date) -> Double? {
        guard validRange(from: from, to: to) else { return nil }
        var measured = false
        var seconds = 0.0
        for sessionID in ownedTurns.keys.sorted() {
            let intervals = closedIntervals(ownedTurns[sessionID] ?? [], from: from, to: to)
            if !intervals.isEmpty { measured = true }
            seconds += duration(merged(intervals))
            guard seconds.isFinite else { return nil }
        }
        guard measured else { return nil }
        let average = seconds / to.timeIntervalSince(from)
        return average.isFinite ? average : nil
    }

    /// Fixed-width load buckets (default 15 minutes) over merged intervals.
    public static func load(_ lanes: [Lane], from: Date, to: Date, bucketSeconds: TimeInterval = 900) -> [LoadBucket] {
        guard validRange(from: from, to: to), bucketSeconds.isFinite, bucketSeconds > 0 else { return [] }
        let requestedCount = (to.timeIntervalSince(from) / bucketSeconds).rounded(.up)
        // Validate before converting to Int; corrupted dates or a tiny bucket
        // size must not trap or allocate an unbounded chart series.
        guard requestedCount.isFinite, requestedCount > 0, requestedCount <= 4_096 else { return [] }
        let count = Int(requestedCount)
        var seconds = [Double](repeating: 0, count: count)
        let byAgent = agentIntervals(lanes, from: from, to: to)
        // Stable accumulation order keeps fractional-second exports identical
        // even when source sessions arrive in a different order.
        for agentID in byAgent.keys.sorted() {
            guard let intervals = byAgent[agentID] else { continue }
            for interval in intervals {
                let first = min(count - 1, Int(interval.start.timeIntervalSince(from) / bucketSeconds))
                let last = min(count - 1, Int(interval.end.timeIntervalSince(from) / bucketSeconds))
                for index in first ... last {
                    let bucketStart = from.addingTimeInterval(Double(index) * bucketSeconds)
                    let bucketEnd = min(to, from.addingTimeInterval(Double(index + 1) * bucketSeconds))
                    let overlap = min(interval.end, bucketEnd).timeIntervalSince(max(interval.start, bucketStart))
                    if overlap > 0 { seconds[index] += overlap }
                }
            }
        }
        return (0 ..< count).map { index in
            let start = from.addingTimeInterval(Double(index) * bucketSeconds)
            let end = min(to, from.addingTimeInterval(Double(index + 1) * bucketSeconds))
            let length = end.timeIntervalSince(start)
            return LoadBucket(start: start, end: end, meanAgents: length > 0 ? seconds[index] / length : 0)
        }
    }

    public struct ConcurrencyPoint: Equatable, Identifiable, Sendable {
        public var time: Date
        public var agents: Int
        public var id: Date { time }
    }

    /// Exact event sweep of recorded intervals. Short bursts are not sampled
    /// away, so max(agents) is the observed peak. Values apply from their time
    /// until the next point (step-end rendering); simultaneous starts/ends are
    /// combined and `to` always closes at zero. `buckets` is retained for source
    /// compatibility, but no longer compromises the accuracy of the curve.
    public static func concurrency(_ lanes: [Lane], from: Date, to: Date, buckets: Int = 96) -> [ConcurrencyPoint] {
        guard buckets > 0, validRange(from: from, to: to) else { return [] }
        let byAgent = agentIntervals(lanes, from: from, to: to)
        var events: [Date: Int] = [from: 0, to: 0]
        for intervals in byAgent.values {
            for interval in intervals {
                events[interval.start, default: 0] += 1
                events[interval.end, default: 0] -= 1
            }
        }
        var count = 0
        return events.keys.sorted().map { time in
            count += events[time, default: 0]
            return ConcurrencyPoint(time: time, agents: count)
        }
    }

    // MARK: KPIs

    public struct Period: Equatable, Sendable {
        public var turns: Int
        public var tokens: Int?
        public var outputTokens: Int?
        public var activeSeconds: Double?
        public var agentSeconds: Double?
        public var submissions: Int?
        public var artifacts: Int
        public var sessions: Int
        /// Turns in the period that reported a token total.
        public var tokenReceipts: Int
        public var outputTokenReceipts: Int = 0
        public var partialTokenReceipts: Int = 0
        public var partialOutputTokenReceipts: Int = 0

        /// Share of turns with a token total; nil for an empty period.
        public var tokenCoverage: Double? { turns > 0 ? Double(tokenReceipts) / Double(turns) : nil }
        public var outputTokenCoverage: Double? { turns > 0 ? Double(outputTokenReceipts) / Double(turns) : nil }
    }

    /// A percentage change needs full observed-turn coverage on both sides.
    /// Equal but sparse coverage is not evidence of comparable missing usage.
    /// Bounded transcript subtotals remain displayable but do not support a delta.
    public static func comparableTokenDelta(_ current: Period, _ previous: Period?) -> Bool {
        guard let previous else { return false }
        return current.turns > 0 && previous.turns > 0 && current.tokenReceipts == current.turns
            && previous.tokenReceipts == previous.turns && current.partialTokenReceipts == 0
            && previous.partialTokenReceipts == 0 && current.tokens != nil && previous.tokens != nil
    }

    public static func comparableOutputTokenDelta(_ current: Period, _ previous: Period?) -> Bool {
        guard let previous else { return false }
        return current.turns > 0 && previous.turns > 0 && current.outputTokenReceipts == current.turns
            && previous.outputTokenReceipts == previous.turns && current.partialOutputTokenReceipts == 0
            && previous.partialOutputTokenReceipts == 0 && current.outputTokens != nil && previous.outputTokens != nil
    }

    public static func period(_ turns: [ActivityTurn], sessions: Int, from: Date?, to: Date?) -> Period {
        let turns = uniqueTurns(turns)
        let scoped = scopedTurns(turns, from: from, to: to)
        let intervals = closedIntervals(turns, from: from, to: to)
        return Period(
            turns: scoped.count,
            tokens: measuredTotal(scoped.map(\.usage.total)),
            outputTokens: measuredTotal(scoped.map(\.usage.output)),
            activeSeconds: intervals.isEmpty ? nil : duration(merged(intervals)),
            // Same clipped evidence as activeSeconds; adding a whole duration
            // at completion would inflate parallelism across period boundaries.
            agentSeconds: intervals.isEmpty ? nil : duration(intervals),
            submissions: measuredTotal(scoped.map(\.promptCount)),
            artifacts: scoped.reduce(0) { $0 + $1.artifacts.count },
            sessions: max(0, sessions),
            tokenReceipts: scoped.filter { nonnegative($0.usage.total) != nil }.count,
            outputTokenReceipts: scoped.filter { nonnegative($0.usage.output) != nil }.count,
            partialTokenReceipts: scoped.filter { nonnegative($0.usage.total) != nil && $0.usageIsPartial == true }.count,
            partialOutputTokenReceipts: scoped.filter { nonnegative($0.usage.output) != nil && $0.usageIsPartial == true }.count
        )
    }

    /// Relative change, nil when either side is unknown or the base is zero.
    public static func delta(_ current: Double?, _ previous: Double?) -> Double? {
        guard let current, let previous, current.isFinite, previous.isFinite, current >= 0, previous > 0 else { return nil }
        let result = (current - previous) / previous
        return result.isFinite ? result : nil
    }

    // MARK: Account-wide provider dates

    public struct AccountDay: Equatable, Identifiable, Sendable {
        /// Preserve the provider's date label: the account endpoint does not
        /// establish a reporting time zone or local session attribution.
        public var date: String
        /// UTC-midnight chart coordinate only, not a claim of source time zone.
        public var day: Date
        public var tokens: Int?
        public var conflicting: Bool
        public var id: String { date }
    }

    public struct AccountSummary: Equatable, Sendable {
        public var days: [AccountDay]
        /// Known-day subtotal, not an estimate of missing days. Nil means no
        /// measurements or an unrepresentable sum; measured zero stays zero.
        public var tokens: Int?
        public var overflow: Bool
        public var recordedDays: Int { days.filter { $0.tokens != nil }.count }
        public var missingDays: Int { days.count - recordedDays }
        public var conflictingDays: Int { days.filter(\.conflicting).count }
        public var isComplete: Bool { !days.isEmpty && missingDays == 0 && !overflow }
    }

    /// Strict Gregorian YYYY-MM-DD, independent of a user's Buddhist calendar
    /// or the machine time zone. Invalid dates are not normalized into March.
    public static func accountDate(_ label: String) -> Date? {
        let bytes = Array(label.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }),
              let year = Int(label.prefix(4)), year > 0,
              let month = Int(label.dropFirst(5).prefix(2)),
              let day = Int(label.suffix(2)) else { return nil }
        let calendar = calendar(TimeZone(secondsFromGMT: 0)!)
        guard let value = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let actual = calendar.dateComponents([.year, .month, .day], from: value)
        return actual.year == year && actual.month == month && actual.day == day ? value : nil
    }

    /// Identical repeated rows count once. Conflicting rows are unknown, not
    /// added together or arbitrarily treated as the newest without provenance.
    public static func accountDays(_ rows: [ActivityAccountDay]) -> [AccountDay] {
        var values: [String: Set<Int>] = [:]
        var dates: [String: Date] = [:]
        for row in rows {
            guard let day = accountDate(row.date) else { continue }
            dates[row.date] = day
            values[row.date, default: []].insert(row.tokens)
        }
        return values.keys.sorted().compactMap { label in
            guard let candidates = values[label], let day = dates[label] else { return nil }
            let known = candidates.count == 1 ? candidates.first.flatMap { $0 >= 0 ? $0 : nil } : nil
            return AccountDay(date: label, day: day, tokens: known, conflicting: candidates.count > 1)
        }
    }

    /// Half-open provider-date range. Missing rows remain explicit nil bins;
    /// this must not be blended with a precisely timed local-session window.
    public static func accountSummary(_ rows: [ActivityAccountDay], from startLabel: String, to endLabel: String) -> AccountSummary? {
        guard let start = accountDate(startLabel), let end = accountDate(endLabel), end > start else { return nil }
        let calendar = calendar(TimeZone(secondsFromGMT: 0)!)
        guard let count = calendar.dateComponents([.day], from: start, to: end).day, count <= 36_600 else { return nil }
        let byDate = Dictionary(uniqueKeysWithValues: accountDays(rows).map { ($0.day, $0) })
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let days = (0..<count).compactMap { index -> AccountDay? in
            guard let day = calendar.date(byAdding: .day, value: index, to: start) else { return nil }
            return byDate[day] ?? AccountDay(date: formatter.string(from: day), day: day, tokens: nil, conflicting: false)
        }
        let known = days.compactMap(\.tokens)
        let tokens = measuredTotal(known.map(Optional.some))
        return AccountSummary(days: days, tokens: tokens, overflow: !known.isEmpty && tokens == nil)
    }

    // MARK: Plan runway

    public enum Runway: Equatable, Sendable {
        /// At the average pace since the window opened, the limit is reached
        /// at this moment, before the window resets.
        case exhausts(Date)
        /// The same pace lasts past the reset.
        case lastsUntilReset(Date)
        /// Too little evidence: no reset time, a fresh window, or no usage.
        case unknown
    }

    public static func runway(_ window: QuotaWindow, now: Date = Date()) -> Runway {
        guard let reset = window.resetAt, let minutes = window.durationMinutes, minutes > 0, reset > now,
              window.usedRatio.isFinite, (0...1).contains(window.usedRatio), reset.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite else { return .unknown }
        let opened = reset.addingTimeInterval(-Double(minutes) * 60)
        let elapsed = now.timeIntervalSince(opened)
        guard elapsed.isFinite, elapsed >= 900, window.usedRatio > 0.005 else { return .unknown }
        if window.usedRatio >= 1 { return .exhausts(now) }
        let rate = window.usedRatio / elapsed
        let exhaust = now.addingTimeInterval((1 - window.usedRatio) / rate)
        guard exhaust.timeIntervalSinceReferenceDate.isFinite else { return .unknown }
        return exhaust < reset ? .exhausts(exhaust) : .lastsUntilReset(reset)
    }

    // MARK: Evidence normalization

    /// Callers commonly pass already-normalized turns, but a repeated fork
    /// receipt must not multiply counts if they do not. Input order is the
    /// correction order, matching the merge semantics of the activity store.
    private static func uniqueTurns(_ turns: [ActivityTurn]) -> [ActivityTurn] {
        var values: [String: ActivityTurn] = [:]
        for turn in turns { values[turn.id] = values[turn.id]?.merging(turn) ?? turn }
        return values.values.sorted { $0.id < $1.id }
    }

    private static func nonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    /// The visual lower bound saturates instead of trapping on a corrupt or
    /// enormous source count. A measured total cannot represent overflow.
    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int.max : result.partialValue
    }

    private static func measuredTotal(_ values: [Int?]) -> Int? {
        let values = values.compactMap(nonnegative)
        guard !values.isEmpty else { return nil }
        var total = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }

    private static func validRange(from: Date, to: Date) -> Bool {
        from.timeIntervalSinceReferenceDate.isFinite && to.timeIntervalSinceReferenceDate.isFinite
            && to > from && to.timeIntervalSince(from).isFinite
    }

    /// A lane ID identifies one agent. Merge repeated snapshots before both
    /// load and concurrency so either view uses exactly the same interval set.
    private static func agentIntervals(_ lanes: [Lane], from: Date, to: Date) -> [String: [Interval]] {
        var byAgent: [String: [Interval]] = [:]
        for lane in lanes {
            byAgent[lane.id, default: []] += lane.intervals.compactMap { interval in
                guard interval.start.timeIntervalSinceReferenceDate.isFinite,
                      interval.end.timeIntervalSinceReferenceDate.isFinite else { return nil }
                let start = max(from, interval.start), end = min(to, interval.end)
                return end > start ? Interval(start: start, end: end) : nil
            }
        }
        return byAgent.mapValues(merged)
    }

    private static func closedIntervals(_ turns: [ActivityTurn], from: Date?, to: Date?) -> [Interval] {
        if let from, !from.timeIntervalSinceReferenceDate.isFinite { return [] }
        if let to, !to.timeIntervalSinceReferenceDate.isFinite { return [] }
        if let from, let to, to <= from { return [] }
        return turns.compactMap { turn in
            guard let start = turn.startedAt, let end = turn.completedAt, end >= start,
                  start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite else { return nil }
            let a = max(start, from ?? start), b = min(end, to ?? end)
            // Zero-duration receipts are valid, but an interval merely touching
            // a reporting boundary does not manufacture a measured zero there.
            guard b > a || (start == end && (from.map { start >= $0 } ?? true) && (to.map { start < $0 } ?? true)) else { return nil }
            return Interval(start: a, end: b)
        }
    }

    private static func merged(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var result: [Interval] = []
        for interval in sorted {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1].end = max(last.end, interval.end)
            } else { result.append(interval) }
        }
        return result
    }

    private static func duration(_ intervals: [Interval]) -> Double {
        intervals.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
    }
}
