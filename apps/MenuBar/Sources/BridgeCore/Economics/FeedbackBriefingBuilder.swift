import Foundation

/// The briefing a person pastes into Codex or Claude to steer the next work
/// cycle. It renders the report's own facts, assumptions and gaps; it never
/// recomputes them, sends anything or changes a session.
public enum FeedbackBriefingBuilder {
    public static func markdown(_ report: EconomicReport) -> String {
        var lines: [String] = []
        let period = report.period
        lines.append("# Work economics briefing: \(period.label)")
        lines.append("")
        let window = (period.from.map { date($0, period.timeZone) } ?? "the first saved session") + " to " + date(period.to, period.timeZone)
        lines.append("Report `\(report.reportID)` · \(window) (\(period.timeZone)) · from the activity snapshot of \(date(report.snapshot.asOf, period.timeZone))")
        let projects = report.scope.projects.map(\.name)
        var scope = projects.isEmpty ? "no scanned repositories" : (projects.count <= 4 ? projects.joined(separator: ", ") : "\(projects.count) repositories")
        if report.scope.projectFilter != nil { scope = "project " + scope }
        lines.append("Scope: \(scope) · \(count(report.scope.sessions)) \(report.scope.sessions == 1 ? "session" : "sessions") · \(report.scope.provider.map { "\($0) only" } ?? "all agents")")
        lines.append("")

        lines.append("## Delivered")
        let outcomes = report.outcomes
        lines.append("- \(outcomes.accepted) accepted \(outcomes.accepted == 1 ? "outcome" : "outcomes"), \(outcomes.pendingCandidates) waiting for a decision, \(outcomes.rejected) rejected.")
        lines.append("- \(count(outcomes.commitsInPeriod)) commits in the period (+\(count(outcomes.linesInPeriod.additions)) / −\(count(outcomes.linesInPeriod.deletions)) lines), \(count(outcomes.commitsInAcceptedOutcomes)) of them in accepted outcomes.")
        for item in outcomes.items.prefix(20) {
            var parts = ["**\(item.title)**", item.deliveryStandard.title.lowercased(), "landed \(date(item.landedAt, period.timeZone))"]
            parts.append("\(item.commits) \(item.commits == 1 ? "commit" : "commits")" + (item.lines.map { " (+\(count($0.additions)) / −\(count($0.deletions)))" } ?? ""))
            if !item.repositories.isEmpty { parts.append(item.repositories.joined(separator: ", ")) }
            if let effort = item.effort {
                var text = "estimated \(hours(effort.hours))"
                text += effort.sizeClass.map { ", size \($0)" } ?? ""
                text += ", by \(effort.assessor.kind == .human ? "a person" : effort.assessor.identity)"
                if effort.disagreement { text += ", estimates disagree" }
                if effort.stale { text += ", estimated before the last revision" }
                parts.append(text)
            } else { parts.append("no effort estimate") }
            parts.append(item.operatorTime.state == .known ? "hands-on \(span(item.operatorTime.lowHours, item.operatorTime.highHours)) h" : "hands-on time unknown")
            if item.revertedCommits > 0 { parts.append("\(item.revertedCommits) of its commits later reverted") }
            lines.append("- " + parts.joined(separator: " · "))
            let commits = item.evidence.filter { $0.kind == .commit }.map { String($0.ref.prefix(12)) }
            if !commits.isEmpty { lines.append("  Evidence: " + commits.prefix(12).joined(separator: ", ") + (commits.count > 12 ? " and \(commits.count - 12) more" : "")) }
            lines.append("  Outcome ID: `\(item.outcomeID)`")
        }
        if outcomes.items.count > 20 { lines.append("- …and \(outcomes.items.count - 20) more accepted outcomes in the report.") }
        if !outcomes.pending.isEmpty {
            lines.append("- Waiting for a decision:")
            for candidate in outcomes.pending.prefix(10) {
                lines.append("  - `\(candidate.candidateID)` \(candidate.title) · \(candidate.commits) \(candidate.commits == 1 ? "commit" : "commits") (+\(count(candidate.lines.additions)) / −\(count(candidate.lines.deletions))) · \(candidate.repositories.joined(separator: ", "))")
            }
            if outcomes.pending.count > 10 { lines.append("  - …and \(outcomes.pendingCandidates - 10) more.") }
        }
        for correction in outcomes.corrections {
            lines.append("- Withdrawn: **\(correction.title)** (\(correction.reason.rawValue.replacingOccurrences(of: "_", with: " ")), landed \(date(correction.landedAt, period.timeZone))).")
        }
        lines.append("")

        lines.append("## Economics")
        let usage = report.usage
        var usageLine = "- Usage (this Mac's saved history): " + (usage.tokens.map { "\(count(Int($0.value))) tokens\(usage.tokensArePartial ? " known (partial)" : "")" } ?? "tokens unknown")
        if let output = usage.outputTokens { usageLine += ", \(count(Int(output.value))) written" }
        if let share = usage.rereadShare { usageLine += ", \(EconomicReportBuilder.percent(share)) re-read context" }
        usageLine += "; \(count(usage.modelSteps)) model steps."
        lines.append(usageLine)
        for provider in usage.byProvider {
            lines.append("  - \(provider.provider): \(provider.tokens.map { count(Int($0.value)) } ?? "unknown") tokens, \(count(provider.modelSteps)) steps, \(provider.sessions) sessions")
        }
        let time = report.time
        if let active = time.activeSeconds {
            lines.append("- Agents worked \(duration(active)) of wall-clock time" + (time.agentSeconds.map { ", \(duration($0)) summed across parallel sessions" } ?? "") + ". Agent time isn't human effort.")
        }
        switch time.operatorTime.state {
        case .known: lines.append("- Hands-on time: \(span(time.operatorTime.hours?.low, time.operatorTime.hours?.high)) h across \(time.operatorTime.outcomesWithTime) accepted \(time.operatorTime.outcomesWithTime == 1 ? "outcome" : "outcomes").")
        case .partial: lines.append("- Hands-on time: \(span(time.operatorTime.hours?.low, time.operatorTime.hours?.high)) h recorded for \(time.operatorTime.outcomesWithTime) of \(time.operatorTime.outcomesWithTime + time.operatorTime.outcomesWithoutTime) accepted outcomes.")
        case .unknown: lines.append("- Hands-on time: not recorded.")
        }
        let costs = report.costs
        switch costs.state {
        case .known:
            let total = costs.total.map(money) ?? "0"
            lines.append("- Tooling: \(total)" + (costs.tooling.isEmpty ? "" : " (" + costs.tooling.map { "\($0.label): \(money($0.amount)) = \($0.calculation)" }.joined(separator: "; ") + ")"))
        case .unknown: lines.append("- Tooling: unknown (no subscriptions set).")
        case .mixedCurrencies: lines.append("- Tooling: " + costs.tooling.map { "\($0.label) \(money($0.amount))" }.joined(separator: ", ") + " (different currencies, not added).")
        }
        let effort = report.effort
        if let hours = effort.hours {
            lines.append("- Estimated human effort (\(effort.baseline.title.lowercased())): \(self.hours(hours))" + (effort.personDays.map { " = \(range($0)) person-days at \(effort.hoursPerDay) h a day" } ?? "")
                         + (effort.unestimatedOutcomes > 0 ? "; \(effort.unestimatedOutcomes) accepted \(effort.unestimatedOutcomes == 1 ? "outcome has" : "outcomes have") no estimate yet" : "") + ".")
        } else {
            lines.append("- Estimated human effort: none yet" + (effort.unestimatedOutcomes > 0 ? " (\(effort.unestimatedOutcomes) accepted \(effort.unestimatedOutcomes == 1 ? "outcome needs" : "outcomes need") an estimate)." : "."))
        }
        let economics = report.economics
        let rate = economics.rate
        if let gross = economics.grossLaborEquivalent {
            lines.append("- Wage equivalent at \(rate.label) (\(money(rate.hourly))/h): \(moneyRange(gross)). Not revenue, market value or cash saved.")
        }
        if let net = economics.netOpportunity {
            lines.append("- Net opportunity benefit after hands-on time at \(money(economics.operatorRate.hourly))/h and tooling: \(moneyRange(net)).")
        } else {
            lines.append("- Net opportunity benefit: unknown until " + economics.missing.map(missingPhrase).joined(separator: ", ") + ".")
        }
        if let leverage = economics.leverage {
            lines.append("- Leverage: \(leverage.low)–\(leverage.high)× (base \(leverage.base)×) estimated human hours per hands-on hour.")
        }
        lines.append("")

        lines.append("## Friction")
        if report.friction.isEmpty { lines.append("- Nothing stood out in the records.") }
        for item in report.friction {
            var text = "- " + item.detail
            if let tokens = item.tokens, item.kind == .sessionsWithoutCommits { text += " (\(count(Int(tokens.value))) tokens)" }
            if !item.evidence.isEmpty { text += " Evidence: " + item.evidence.prefix(8).joined(separator: ", ") }
            lines.append(text)
        }
        lines.append("")

        lines.append("## Uncertainty")
        for note in report.uncertainty { lines.append("- " + note.message) }
        lines.append("")

        lines.append("## Suggested next prompt")
        lines.append("")
        for line in report.nextPrompt.split(separator: "\n", omittingEmptySubsequences: false) { lines.append("> " + line) }
        lines.append("")
        lines.append("---")
        lines.append("Every figure above comes from report `\(report.reportID)` (\(report.schemaVersion)). Usage is from accounting result `\(report.snapshot.accountingFingerprint.dropFirst(7).prefix(16))…`; estimates follow \(effort.rubricVersion). Formulas: estimated hours × rate = wage equivalent; minus hands-on time × operator rate and tooling = net benefit.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// One or two concrete instructions for the next cycle, chosen from the
    /// report's gaps in order of how much they block the economics.
    public static func nextPrompt(_ report: EconomicReport) -> String {
        var steps: [String] = []
        let outcomes = report.outcomes
        if report.uncertainty.contains(where: { $0.code == "no_repository_scan" }) {
            steps.append("Run Scan projects in Agent Hub (or `bridge activity repositories`) so commits can be linked to sessions, then rebuild this report.")
        }
        if outcomes.pendingCandidates > 0 {
            steps.append("Go through the \(outcomes.pendingCandidates) suggested \(outcomes.pendingCandidates == 1 ? "outcome" : "outcomes") with me. For each, I'll say whether it's accepted work, its delivery standard (prototype, internal tool or production) and roughly how many hands-on hours I spent; record them with `bridge economics accept --candidate <id>` or `bridge economics reject --candidate <id>`.")
        }
        let unestimated = outcomes.items.filter { $0.effort == nil }
        if !unestimated.isEmpty {
            steps.append("Use the economic-work-review skill to estimate human effort for \(unestimated.count == 1 ? "this accepted outcome" : "these \(unestimated.count) accepted outcomes") (\(unestimated.prefix(8).map { "`\($0.outcomeID)`" }.joined(separator: ", "))) under the \(report.effort.baseline.rawValue) baseline. Read only their evidence commits, return effort-assessment/1 JSON citing them, and don't change the repository.")
        }
        if outcomes.accepted > 0, report.time.operatorTime.state != .known {
            steps.append("Record my hands-on hours for accepted outcomes that have none, with `bridge economics revise --outcome <id> --hands-on <low>-<high>`.")
        }
        if let share = report.usage.rereadShare, share >= ExactDecimal("0.8")! {
            steps.append("\(EconomicReportBuilder.percent(share)) of tokens were context re-read from cache. Start a fresh session for each separate task and keep AGENTS.md and CLAUDE.md short, so each step re-reads less.")
        }
        if let friction = report.friction.first(where: { $0.kind == .revertedCommits }) {
            steps.append("\(friction.count) \(friction.count == 1 ? "commit was" : "commits were") reverted. Before committing, run the project's checks and say which ones passed.")
        }
        if let friction = report.friction.first(where: { $0.kind == .sessionsWithoutCommits }), report.scope.sessions > 0, friction.count * 2 >= report.scope.sessions {
            steps.append("Many sessions ended without a linked commit. Before starting the next task, write down the check that will show it's done.")
        }
        if steps.isEmpty {
            steps.append("No inputs are missing. Pick the next goal, state its acceptance check before starting, and note hands-on time when it lands.")
        }
        return steps.prefix(2).joined(separator: "\n")
    }

    // MARK: Formatting

    static func count(_ value: Int) -> String { grouped(String(value)) }

    static func grouped(_ text: String) -> String {
        let negative = text.hasPrefix("-")
        let parts = text.drop { $0 == "-" }.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        var integer = String(parts[0]), groups: [String] = []
        while integer.count > 3 { groups.insert(String(integer.suffix(3)), at: 0); integer.removeLast(3) }
        groups.insert(integer, at: 0)
        return (negative ? "−" : "") + groups.joined(separator: ",") + (parts.count > 1 ? "." + parts[1] : "")
    }

    static func money(_ value: MoneyAmount) -> String { grouped(cents(value.amount)) + " " + value.currency }

    static func moneyRange(_ value: MoneyRange) -> String {
        "\(grouped(cents(value.low)))–\(grouped(cents(value.high))) \(value.currency) (base \(grouped(cents(value.base))))"
    }

    static func cents(_ value: ExactDecimal) -> String {
        let text = value.rounded(scale: 2).description
        guard let dot = text.firstIndex(of: ".") else { return text + ".00" }
        let fraction = text[text.index(after: dot)...]
        return fraction.count == 1 ? text + "0" : text
    }

    static func hours(_ value: EstimateRange) -> String { "\(value.low)–\(value.high) h (base \(value.base) h)" }

    static func range(_ value: EstimateRange) -> String { "\(value.low)–\(value.high) (base \(value.base))" }

    static func span(_ low: ExactDecimal?, _ high: ExactDecimal?) -> String {
        guard let low, let high else { return "?" }
        return low == high ? low.description : "\(low)–\(high)"
    }

    static func duration(_ seconds: Int) -> String {
        let hours = Double(seconds) / 3_600
        return hours >= 1 ? String(format: "%.1f h", hours) : "\(max(1, seconds / 60)) min"
    }

    static func missingPhrase(_ code: String) -> String {
        switch code {
        case "accepted_outcomes": return "work is accepted"
        case "effort_estimates": return "every accepted outcome has an estimate"
        case "operator_time": return "hands-on time is recorded"
        case "tooling_cost": return "subscriptions are set"
        case "single_currency": return "rates and subscriptions share a currency"
        default: return code
        }
    }

    /// Gregorian, so locales with other calendars still print the same date.
    static func date(_ value: Date, _ zone: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone) ?? TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: value)
    }
}
