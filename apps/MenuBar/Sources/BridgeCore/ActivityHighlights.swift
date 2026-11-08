import Foundation

/// One plain-language observation worth a person's attention. Highlights are
/// derived only from measured evidence; when a fact cannot be established the
/// highlight is omitted rather than guessed.
public struct ActivityHighlight: Equatable, Identifiable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case planPace, planLow, failures, busiestDay, busiestHour, overnight, parallel, streak
        case contextReuse, providerShare, longestTurn, topProject, planHealthy
        /// Skills page observations (`SkillReport`); never produced by `make`.
        case skillGap, skillReread, skillDrift, skillListing, skillEdited, skillLeader, skillIdle
        /// Instruction-file observations (`InstructionReport`); never produced by `make`.
        case instructionsDiffer, instructionsMissing, instructionsTruncated, instructionsHeavy, instructionsEdited, instructionsShared
    }

    /// Alert: act soon. Warning: worth watching. Notable: unusual. Positive:
    /// good news. Neutral: informative context.
    public enum Tone: Int, Comparable, Sendable {
        case alert, warning, notable, positive, neutral
        public static func < (lhs: Tone, rhs: Tone) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var kind: Kind
    public var tone: Tone
    /// SF Symbol name.
    public var symbol: String
    /// The short figure shown large: "16h", "400", "99%".
    public var value: String
    public var title: String
    /// One short line of supporting fact. Methodology belongs in `note`.
    public var detail: String
    /// How the figure was measured and what it does not mean. Shown on demand
    /// (hover or accessibility hint), never in the card body.
    public var note: String?
    /// Tints provider-specific highlights.
    public var provider: AgentName?
    /// Session to open when the highlight is clicked.
    public var sessionID: String?

    public var id: String { kind.rawValue + (provider.map { ":" + $0.rawValue } ?? "") }

    public init(kind: Kind, tone: Tone, symbol: String, value: String, title: String, detail: String, note: String? = nil,
                provider: AgentName? = nil, sessionID: String? = nil) {
        self.kind = kind; self.tone = tone; self.symbol = symbol; self.value = value
        self.title = title; self.detail = detail; self.note = note; self.provider = provider; self.sessionID = sessionID
    }
}

public enum ActivityHighlights {
    public struct Input: Sendable {
        public var sessions: [ActivitySession]
        public var from: Date?
        public var to: Date
        public var quotas: [AgentName: QuotaEstimate]
        public var account: ActivityAccountUsage?
        public var timeZone: TimeZone
        public var locale: Locale
        public var accounting: ActivityAccounting.Report?
        /// Provider plan readings age against wall time, independently of the
        /// frozen local-history snapshot. nil preserves deterministic callers.
        public var providerNow: Date?

        public init(sessions: [ActivitySession], from: Date?, to: Date, quotas: [AgentName: QuotaEstimate] = [:],
                    account: ActivityAccountUsage? = nil, timeZone: TimeZone = ActivityAnalytics.reportingTimeZone,
                    locale: Locale = .current, accounting: ActivityAccounting.Report? = nil, providerNow: Date? = nil) {
            self.sessions = sessions; self.from = from; self.to = to; self.quotas = quotas
            self.account = account; self.timeZone = timeZone; self.locale = locale
            self.accounting = accounting
            self.providerNow = providerNow
        }
    }

    /// Ranked by urgency, then by how unusual the observation is.
    public static func make(_ input: Input, limit: Int = 8) -> [ActivityHighlight] {
        let context = Context(input)
        var results: [ActivityHighlight] = []
        results += plan(context)
        results += [failures(context), context.isShortWindow ? busiestHour(context) : busiestDay(context), overnight(context), parallel(context), streak(context),
                    contextReuse(context), providerShare(context), longestTurn(context), topProject(context)].compactMap { $0 }
        let order = Dictionary(uniqueKeysWithValues: ActivityHighlight.Kind.allCases.enumerated().map { ($1, $0) })
        return Array(results.sorted {
            $0.tone != $1.tone ? $0.tone < $1.tone : (order[$0.kind] ?? 0) < (order[$1.kind] ?? 0)
        }.prefix(max(0, limit)))
    }

    public static func make(_ input: Input, accounting: ActivityAccounting.Report, limit: Int = 8) -> [ActivityHighlight] {
        var input = input
        input.accounting = accounting
        return make(input, limit: limit)
    }

    // MARK: Plan capacity

    static func plan(_ c: Context) -> [ActivityHighlight] {
        var urgent: [ActivityHighlight] = []
        var healthy: [(AgentName, Double)] = []
        var anyConcern = false
        for agent in [AgentName.claude, .codex, .grok] {
            guard let estimate = c.input.quotas[agent],
                  ActivityPresentationPolicy.quotaState(estimate, now: c.providerNow) == .fresh else { continue }
            let owner = ModelNaming.planOwner(agent)
            var best: (highlight: ActivityHighlight, rank: Double)?
            var minimumLeft = 1.0
            for window in estimate.windows {
                guard ActivityPresentationPolicy.isCurrentWindow(window, now: c.providerNow),
                      let left = ActivityPresentationPolicy.remainingFraction(window) else { continue }
                minimumLeft = min(minimumLeft, left)
                let name = windowName(window.label)
                if window.usedRatio >= 0.9 {
                    let resetText = window.resetAt.map { "resets \(c.dayTime($0))" } ?? "reset time not shared"
                    let credits = CreditBalancePresentation.make(estimate, now: c.providerNow)
                    let fullCodex = agent == .codex && window.usedRatio >= 1
                    let hasCredits = credits.freshness == .fresh && [.available, .unlimited].contains(credits.state)
                    let highlight = ActivityHighlight(kind: .planLow, tone: fullCodex && hasCredits ? .warning : .alert, symbol: "gauge.with.dots.needle.100percent",
                                                      value: "\(percent(left))%", title: fullCodex ? "ChatGPT included allowance used up" : "\(owner) \(name) is almost used up",
                                                      detail: "\(percent(left))% left · \(resetText)" + (fullCodex && hasCredits ? " · Credits also available when read" : ""),
                                                      note: "Read from your \(owner) plan.", provider: agent)
                    if best == nil || 0 < best!.rank { best = (highlight, 0) }
                    continue
                }
                guard case let .exhausts(date) = ActivityPresentationPolicy.runway(window, estimate: estimate, now: c.providerNow),
                      let reset = window.resetAt else { continue }
                if date <= c.providerNow {
                    let highlight = ActivityHighlight(kind: .planPace, tone: .warning, symbol: "arrow.clockwise.circle",
                                                      value: "Refresh", title: "Refresh \(owner) \(name)",
                                                      detail: "Earlier forecast has passed · \(percent(left))% left when read",
                                                      note: "The earlier pace forecast is not a new usage measurement. Refresh plan usage to see the current allowance; this does not mean the limit is used up.",
                                                      provider: agent)
                    if best == nil || 0 < best!.rank { best = (highlight, 0) }
                    continue
                }
                let untilEmpty = date.timeIntervalSince(c.providerNow)
                let early = reset.timeIntervalSince(date)
                let highlight = ActivityHighlight(
                    kind: .planPace, tone: untilEmpty < 86_400 ? .alert : .warning,
                    symbol: "gauge.with.dots.needle.67percent", value: c.duration(untilEmpty),
                    title: "\(owner) \(name) could run out \(c.dayTime(date))",
                    detail: "\(c.duration(early)) before it resets · \(percent(left))% left",
                    note: "Forecast from your average pace since the limit last reset. It resets \(c.dayTime(reset)).",
                    provider: agent)
                if best == nil || untilEmpty < best!.rank { best = (highlight, untilEmpty) }
            }
            if let best { urgent.append(best.highlight); anyConcern = true }
            else { healthy.append((agent, minimumLeft)) }
        }
        guard urgent.isEmpty else { return urgent }
        guard !anyConcern, !healthy.isEmpty, healthy.allSatisfy({ $0.1 >= 0.5 }) else { return [] }
        let lowest = healthy.map(\.1).min() ?? 1
        return [ActivityHighlight(kind: .planHealthy, tone: .positive, symbol: "checkmark.seal.fill",
                                  value: "\(percent(lowest))%", title: "Plenty of plan capacity left",
                                  detail: healthy.map { "\(ModelNaming.planOwner($0.0)) \(percent($0.1))% left" }.joined(separator: " · "))]
    }

    // MARK: Work patterns

    static func failures(_ c: Context) -> ActivityHighlight? {
        let records = c.accounting.nativeObservations.filter { item in
            guard let stamp = item.completedAt ?? item.timestamp else { return false }
            return (c.input.from.map { stamp >= $0 } ?? true) && stamp < c.now
        }
        let failed = records.filter { ["failed", "error", "errored"].contains($0.status.lowercased()) }
        let interrupted = records.filter { ["interrupted", "cancelled", "canceled", "aborted"].contains($0.status.lowercased()) }
        let count = failed.count + interrupted.count
        guard count > 0, !records.isEmpty else { return nil }
        let share = Double(count) / Double(records.count)
        var parts: [String] = []
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        if !interrupted.isEmpty { parts.append("\(interrupted.count) interrupted") }
        let worst = Dictionary(grouping: failed + interrupted, by: \.sessionID)
            .filter { !$0.key.isEmpty }.max { $0.value.count < $1.value.count }?.key
        return ActivityHighlight(kind: .failures, tone: share >= 0.05 ? .warning : .neutral, symbol: "exclamationmark.octagon.fill",
                                 value: count.formatted(), title: count == 1 ? "Request didn't finish" : "Requests didn't finish",
                                 detail: "\(parts.joined(separator: " · ").capitalizedFirst) · of \(records.count.formatted())",
                                 note: "Requests that ended with an error or were stopped before finishing. Click to open the session with the most.",
                                 sessionID: worst)
    }

    static func busiestDay(_ c: Context) -> ActivityHighlight? {
        guard c.modelStepDates.count >= 20 else { return nil }
        let byDay = Dictionary(grouping: c.modelStepDates) { c.calendar.startOfDay(for: $0) }.mapValues(\.count)
        guard byDay.count >= 2, let top = byDay.max(by: { $0.value < $1.value }) else { return nil }
        let others = byDay.filter { $0.key != top.key }.values.reduce(0, +)
        // A date with no imported requests is not proof of an idle day.
        // Compare recorded days only, and say that explicitly.
        let otherDays = byDay.count - 1
        let typical = Double(others) / Double(otherDays)
        let name = c.dayName(top.key)
        let busiestNote = "Compared with the other \(otherDays) \(otherDays == 1 ? "day" : "days") with dated model-step receipts in this report. Days with nothing saved aren't counted as idle."
        if top.value > others {
            return ActivityHighlight(kind: .busiestDay, tone: .notable, symbol: "flame.fill", value: top.value.formatted(),
                                     title: "\(name) was the busiest day",
                                     detail: "More model steps than the other \(otherDays) \(otherDays == 1 ? "day" : "days") combined",
                                     note: busiestNote)
        }
        guard typical > 0, Double(top.value) / typical >= 2 else { return nil }
        return ActivityHighlight(kind: .busiestDay, tone: .notable, symbol: "flame.fill", value: top.value.formatted(),
                                 title: "\(name) was the busiest day",
                                 detail: "\(top.value.formatted()) model steps · \(multiple(Double(top.value) / typical)) a typical recorded day",
                                 note: busiestNote)
    }

    /// For windows of a day or so, days are the wrong unit: a rolling 24 hours
    /// splits into two partial dates. Compare clock hours instead.
    static func busiestHour(_ c: Context) -> ActivityHighlight? {
        guard c.modelStepDates.count >= 20, let from = c.input.from, from < c.now else { return nil }
        let byHour = Dictionary(grouping: c.modelStepDates) {
            c.calendar.dateInterval(of: .hour, for: $0)?.start ?? $0
        }.mapValues(\.count).filter { start, _ in
            guard let interval = c.calendar.dateInterval(of: .hour, for: start) else { return false }
            // Rolling windows have two partial edges. Their counts are not
            // comparable to a full hour, nor is a shortened DST clock hour.
            return start >= from && interval.end <= c.now && interval.duration == 3_600
        }
        guard byHour.values.reduce(0, +) >= 20 else { return nil }
        guard byHour.count >= 3, let top = byHour.max(by: { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }) else { return nil }
        let otherHours = byHour.count - 1
        let typical = Double(byHour.filter { $0.key != top.key }.values.reduce(0, +)) / Double(otherHours)
        guard typical > 0, Double(top.value) / typical >= 2 else { return nil }
        let end = c.calendar.date(byAdding: .hour, value: 1, to: top.key) ?? top.key
        let repeatedHour = byHour.keys.contains { date in
            date != top.key && c.calendar.isDate(date, inSameDayAs: top.key)
                && c.calendar.component(.hour, from: date) == c.calendar.component(.hour, from: top.key)
        }
        let offsetChanges = c.input.timeZone.secondsFromGMT(for: top.key) != c.input.timeZone.secondsFromGMT(for: end)
        let template = repeatedHour || offsetChanges ? "jmmz" : "jmm"
        let range = "\(c.format(top.key, template: template))–\(c.format(end, template: template))"
        return ActivityHighlight(kind: .busiestHour, tone: .notable, symbol: "flame.fill", value: top.value.formatted(),
                                 title: "Busiest full hour: \(c.dayName(top.key)), \(range)",
                                 detail: "\(top.value.formatted()) model steps · \(multiple(Double(top.value) / typical)) the other hours' average",
                                 note: "Compared with the other \(otherHours) complete 60-minute \(otherHours == 1 ? "hour" : "hours") with dated model-step receipts. Partial edge hours are excluded. Hours with nothing saved aren't counted as idle.")
    }

    static func overnight(_ c: Context) -> ActivityHighlight? {
        let stamps = c.modelStepDates
        guard stamps.count >= 20 else { return nil }
        let night = stamps.filter { c.calendar.component(.hour, from: $0) < 7 }.count
        let share = Double(night) / Double(stamps.count)
        guard night >= 20, share >= 0.15 else { return nil }
        return ActivityHighlight(kind: .overnight, tone: .notable, symbol: "moon.stars.fill", value: "\(percent(share))%",
                                 title: "Overnight activity",
                                 detail: "\(night.formatted()) model steps between midnight and 7 AM",
                                 note: "Counted by the same provider-event receipts as the report. Agents can run unattended, so this isn't time you worked.")
    }

    static func parallel(_ c: Context) -> ActivityHighlight? {
        let intervals = c.intervals
        guard !intervals.isEmpty else { return nil }
        var events: [(Date, Int)] = []
        for interval in intervals { events.append((interval.0, 1)); events.append((interval.1, -1)) }
        events.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        var current = 0, peak = 0
        var activeSeconds = 0.0, agentSeconds = 0.0
        var previous: Date?
        for event in events {
            if let previous {
                let elapsed = event.0.timeIntervalSince(previous)
                if current > 0 { activeSeconds += elapsed; agentSeconds += elapsed * Double(current) }
            }
            current += event.1; peak = max(peak, current); previous = event.0
        }
        guard peak >= 3 else { return nil }
        var detail = "Several agents shared the work"
        if activeSeconds > 0, agentSeconds.isFinite {
            detail = "\(String(format: "%.1f", agentSeconds / activeSeconds)) on average while working"
        }
        return ActivityHighlight(kind: .parallel, tone: .notable, symbol: "person.3.fill", value: "\(peak)",
                                 title: "Most agents at once", detail: detail,
                                 note: "Overlapping requests from different sessions. Time includes waiting for tools or replies.")
    }

    static func streak(_ c: Context) -> ActivityHighlight? {
        guard let account = c.input.account,
              ActivityPresentationPolicy.isRecent(account.observedAt, now: c.now, within: 86_400),
              let current = account.currentStreakDays, current >= 3 else { return nil }
        let best = account.longestStreakDays
        if let best, best < current { return nil }
        let detail: String
        if let best, best > current { detail = "Best run: \(best) days" }
        else if best == current { detail = "Your best run yet" }
        else { detail = "Best run not reported" }
        return ActivityHighlight(kind: .streak, tone: .positive, symbol: "calendar.badge.checkmark", value: "\(current)",
                                 title: "Days in a row on Codex", detail: detail,
                                 note: "Reported by your OpenAI account across all your devices, not only this Mac.", provider: .codex)
    }

    static func contextReuse(_ c: Context) -> ActivityHighlight? {
        guard c.accounting.totals.composition?.isComplete == true, c.accounting.totals.partialUsageRecords == 0,
              let composition = c.accounting.composition, composition.receipts >= 10,
              composition.total > 0 else { return nil }
        let total = composition.total, cached = composition.rereadContext
        let share = Double(cached) / Double(total)
        guard share >= 0.5, share <= 1 else { return nil }
        // Never round a partial share up to a claim of 100%.
        let shown = share < 1 ? min(99, Int(share * 100)) : 100
        // A ratio stays true whichever total a page shows beside it.
        let detail: String
        let output = composition.output
        if output > 0, cached / output >= 2 {
            detail = "About \(roughly(Double(cached) / Double(output))) re-read for every token written"
        } else {
            detail = "More re-reading than new input"
        }
        return ActivityHighlight(kind: .contextReuse, tone: .neutral, symbol: "arrow.triangle.2.circlepath",
                                 value: "\(shown)%", title: "Most known tokens were re-read context", detail: detail,
                                 note: "From the same normalized token receipts as this report. Only consistent recorded breakdowns count; this is not a guess about missing usage or a plan-consumption measure.")
    }

    static func providerShare(_ c: Context) -> ActivityHighlight? {
        let measured = c.accounting.receipts.filter(\.countsAsModelStep)
        let counts = Dictionary(grouping: measured, by: \.provider).mapValues(\.count)
        guard counts.filter({ $0.key != .none }).count >= 2, measured.count >= 20,
              let top = counts.filter({ $0.key != .none }).max(by: { $0.value < $1.value }) else { return nil }
        let share = Double(top.value) / Double(measured.count)
        guard share >= 0.6 else { return nil }
        let countsText = counts.sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .map { "\($0.value.formatted()) \(productName($0.key))" }.joined(separator: " · ")
        return ActivityHighlight(kind: .providerShare, tone: .neutral, symbol: "chart.pie.fill", value: "\(percent(share))%",
                                 title: "Observed model steps by \(productName(top.key))", detail: countsText,
                                 note: "From normalized model-step receipts, not native conversation turns. This is not a count of human prompts, exact billable attempts or work delivered.", provider: top.key)
    }

    static func longestTurn(_ c: Context) -> ActivityHighlight? {
        let candidates = c.accounting.nativeObservations.compactMap { turn -> (ActivityAccounting.NativeObservation, Double)? in
            guard let start = turn.startedAt, let end = turn.completedAt, end > start,
                  start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite,
                  end.timeIntervalSince(start).isFinite else { return nil }
            return (turn, end.timeIntervalSince(start))
        }
        guard let longest = candidates.max(by: { $0.1 < $1.1 }), longest.1 >= 3_600 else { return nil }
        let session = c.input.sessions.first { $0.id == longest.0.sessionID }
        let title = session.map { "“\(headline($0.title))”" } ?? "One request"
        return ActivityHighlight(kind: .longestTurn, tone: .neutral, symbol: "hourglass", value: c.duration(longest.1),
                                 title: "Longest request",
                                 detail: "\(title)\(session.map { " · \(productName($0.provider))" } ?? "")",
                                 note: "From start to finish, including any waiting.",
                                 provider: session?.provider, sessionID: session?.id)
    }

    static func topProject(_ c: Context) -> ActivityHighlight? {
        let counts = Dictionary(grouping: c.accounting.receipts.filter(\.countsAsModelStep)) { $0.projectPath ?? "" }.mapValues(\.count).filter { !$0.key.isEmpty }
        guard counts.count >= 2, let top = counts.max(by: { $0.value < $1.value }) else { return nil }
        let total = counts.values.reduce(0, +)
        let share = Double(top.value) / Double(max(1, total))
        guard share > 0.5, total >= 20 else { return nil }
        let name = URL(fileURLWithPath: top.key).lastPathComponent
        return ActivityHighlight(kind: .topProject, tone: .neutral, symbol: "folder.fill", value: "\(percent(share))%",
                                 title: "Most observed steps in \(name)",
                                 detail: "\(top.value.formatted()) of \(total.formatted()) project-linked model steps · \(counts.count) projects",
                                 note: "Only model-step receipts with a known project folder count; the same receipt ownership is used by the report totals.")
    }

    // MARK: Helpers

    struct Context {
        let input: Input
        let now: Date
        let calendar: Calendar
        let intervals: [(Date, Date)]
        let accounting: ActivityAccounting.Report
        let modelStepDates: [Date]
        var providerNow: Date { input.providerNow ?? input.to }
        /// A window of about a day or less, where hours are the natural unit.
        var isShortWindow: Bool { input.from.map { input.to.timeIntervalSince($0) <= 36 * 3_600 } ?? false }

        init(_ input: Input) {
            self.input = input
            now = input.to
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = input.timeZone
            calendar.locale = input.locale
            self.calendar = calendar
            let report = input.accounting ?? ActivityAccounting.build(overview: ActivityOverview(generatedAt: input.to, sessions: input.sessions), from: input.from, to: input.to)
            accounting = report
            modelStepDates = report.receipts.filter(\.countsAsModelStep).compactMap(\.timestamp).filter { $0.timeIntervalSinceReferenceDate.isFinite }
            // An agent is a native session, not every overlapping turn it
            // carries. Union the report's already-owned native spans once.
            let nativeGroups = Dictionary(grouping: report.nativeObservations, by: \.sessionID)
            intervals = nativeGroups.keys.sorted().flatMap { id -> [(Date, Date)] in
                let raw = (nativeGroups[id] ?? []).compactMap { turn -> (Date, Date)? in
                    guard let start = turn.startedAt, let end = turn.completedAt, end > start,
                          start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite else { return nil }
                    let a = max(start, input.from ?? start), b = min(end, input.to)
                    return b > a ? (a, b) : nil
                }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
                var merged: [(Date, Date)] = []
                for interval in raw {
                    if let last = merged.last, interval.0 <= last.1 { merged[merged.count - 1].1 = max(last.1, interval.1) }
                    else { merged.append(interval) }
                }
                return merged
            }
        }

        func dayName(_ day: Date) -> String {
            if calendar.isDate(day, inSameDayAs: now) { return "Today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
            return format(day, template: "EEEdMMM")
        }

        func dayTime(_ date: Date) -> String {
            if calendar.isDate(date, inSameDayAs: providerNow) { return "today at \(format(date, template: "jmm"))" }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: providerNow), calendar.isDate(date, inSameDayAs: tomorrow) {
                return "tomorrow at \(format(date, template: "jmm"))"
            }
            return format(date, template: "EEEdMMMjmm")
        }

        func format(_ date: Date, template: String) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = input.timeZone
            formatter.locale = input.locale
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter.string(from: date)
        }

        func duration(_ seconds: TimeInterval) -> String {
            guard seconds.isFinite, seconds >= 0, seconds.rounded() < Double(Int.max) else { return "—" }
            let value = Int(seconds.rounded())
            let d = value / 86_400, h = (value % 86_400) / 3_600, m = (value % 3_600) / 60
            if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
            if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
            return "\(max(1, m))m"
        }
    }

    static func windowName(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("5-hour") || lower.contains("five") { return "5-hour limit" }
        if lower.contains("week") || lower.contains("7-day") || lower.contains("seven") { return "weekly limit" }
        return lower.contains("limit") ? lower : "\(lower) limit"
    }

    static func productName(_ agent: AgentName) -> String {
        switch agent {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .none: return "Unknown"
        }
    }

    static func percent(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    static func multiple(_ value: Double) -> String {
        value >= 10 ? "\(Int(value.rounded()))×" : "\(String(format: "%.1f", value).replacingOccurrences(of: ".0", with: ""))×"
    }

    /// Two significant figures: 783 → "780", 1,234 → "1,200".
    static func roughly(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        let magnitude = pow(10, floor(log10(value)) - 1)
        let rounded = value < 100 ? value.rounded() : (value / magnitude).rounded() * magnitude
        return rounded.formatted(.number.precision(.fractionLength(0)))
    }

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1)))
    }

    static func headline(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        return line.count > 40 ? String(line.prefix(39)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Presentation aggregates

extension ActivityAnalytics {
    /// Requests per weekday and hour for a period, Monday first. Unlike the
    /// day-by-day heatmap this keeps a fixed seven rows for any period length.
    public static func weekHour(_ turns: [ActivityTurn], from: Date?, to: Date?, timeZone: TimeZone = reportingTimeZone) -> [[Int]] {
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let calendar = calendar(timeZone)
        for turn in scopedTurns(turns, from: from, to: to) {
            guard let stamp = timestamp(turn) else { continue }
            let weekday = calendar.component(.weekday, from: stamp) // 1 = Sunday
            let row = (weekday + 5) % 7                               // 0 = Monday
            grid[row][calendar.component(.hour, from: stamp)] += 1
        }
        return grid
    }

    /// Where tokens went, normalised across provider conventions: Codex
    /// reports cached input inside input, Claude reports it separately. Fresh
    /// input is what remains of the total after re-read context, cache writes
    /// and output. Only receipts with total, output and cache reads count.
    public struct Composition: Equatable, Sendable {
        public var freshInput: Int
        public var rereadContext: Int
        public var cacheWrites: Int
        public var output: Int
        public var receipts: Int
        public var total: Int { freshInput + rereadContext + cacheWrites + output }
    }

    public static func composition(_ turns: [ActivityTurn]) -> Composition? {
        composition(usages: scopedTurns(turns, from: nil, to: nil).lazy.map(\.usage))
    }

    /// Linear additive calculation for already-owned, normalized receipts.
    /// The caller owns identity/provenance decisions. Equal usage values are
    /// distinct receipts here; the legacy turn API above still merges turn IDs.
    /// Lazy sequences avoid allocating synthetic turns or another usage array.
    public static func composition<Usages: Sequence>(usages: Usages) -> Composition? where Usages.Element == TokenUsage {
        var value = Composition(freshInput: 0, rereadContext: 0, cacheWrites: 0, output: 0, receipts: 0)
        var aggregateTotal = 0
        for usage in usages {
            guard let total = usage.total, total >= 0, let output = usage.output, output >= 0,
                  let cached = usage.cachedInput, cached >= 0,
                  usage.input.map({ $0 >= 0 }) ?? true else { continue }
            let writes: Int
            if let reported = usage.cacheWriteInput {
                guard reported >= 0 else { continue }
                writes = reported
            } else {
                // Codex includes cache reads in input; Claude does not. A
                // missing write count is zero only when the remaining fields
                // reconcile under one of those documented conventions.
                guard let input = usage.input, input >= 0,
                      let inputAndOutput = ActivityMetrics.knownTotal([input, output]),
                      total == inputAndOutput || ActivityMetrics.knownTotal([inputAndOutput, cached]) == total else { continue }
                writes = 0
            }
            guard let assigned = ActivityMetrics.knownTotal([cached, writes, output]), assigned <= total else { continue }
            let fresh = total - assigned
            let combined = aggregateTotal.addingReportingOverflow(total)
            guard !combined.overflow else { return nil }
            let sums = [value.freshInput.addingReportingOverflow(fresh), value.rereadContext.addingReportingOverflow(cached),
                        value.cacheWrites.addingReportingOverflow(writes), value.output.addingReportingOverflow(output)]
            guard !sums.contains(where: \.overflow) else { return nil }
            value.freshInput = sums[0].partialValue; value.rereadContext = sums[1].partialValue
            value.cacheWrites = sums[2].partialValue; value.output = sums[3].partialValue
            value.receipts += 1
            aggregateTotal = combined.partialValue
        }
        return value.receipts > 0 ? value : nil
    }
}
