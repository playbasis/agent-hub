import BridgeCore
import Charts
import SwiftUI

/// Account-wide figures have a different scope from local session receipts.
/// Keep them in a separate card rather than manufacturing a blended total.
struct AccountUsagePanel: View {
    var account: ActivityAccountUsage
    var fromDate: String
    var toDate: String
    var now: Date

    private var summary: ActivityAnalytics.AccountSummary? {
        ActivityAnalytics.accountSummary(account.daily, from: fromDate, to: toDate)
    }

    @State private var showsHistory = false

    var body: some View {
        let summary = self.summary
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "ChatGPT account", icon: "person.crop.circle",
                       subtitle: "Codex usage on every device · read \(ActivityFormat.relative(account.observedAt, now: now))",
                       info: "Daily Codex totals reported by OpenAI for your whole account, on every device. They overlap with the sessions saved on this Mac, so they're never added to the totals above. A missing day is shown as ×, not zero. Recent days may still update.") {
                // An image has no text baseline; centre it on the title so
                // the header does not grow a blank band above it.
                AgentAvatar(name: "Codex", size: 18)
                    .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 4 }
            }
            if let summary {
                HStack(alignment: .top, spacing: 22) {
                    periodSummary(summary).frame(width: 168, alignment: .leading)
                    dailyChart(summary).frame(maxWidth: .infinity)
                }
                if summary.conflictingDays > 0 {
                    Label("\(summary.conflictingDays) \(summary.conflictingDays == 1 ? "day was" : "days were") reported twice with different totals and \(summary.conflictingDays == 1 ? "is" : "are") left out.", systemImage: "exclamationmark.circle")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
                }
            } else {
                Label("This date range couldn't be read.", systemImage: "calendar.badge.exclamationmark")
                    .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
            }
            Divider().overlay(BridgeTheme.separator)
            HStack(alignment: .center, spacing: 18) {
                historyStats
                Spacer(minLength: 8)
                if historyEnd != nil {
                    Button { withAnimation(.easeOut(duration: 0.18)) { showsHistory.toggle() } } label: {
                        HStack(spacing: 4) {
                            Text(showsHistory ? "Hide year" : "Past year")
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                                .rotationEffect(.degrees(showsHistory ? 180 : 0))
                        }
                    }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
                    .accessibilityIdentifier("hub.account.history")
                }
            }
            if showsHistory, let historyEnd {
                YearHeatmap(days: account.daily, end: historyEnd)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .bridgeCard(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hub.account.usage")
    }

    private func periodSummary(_ summary: ActivityAnalytics.AccountSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.overflow ? "—" : ActivityFormat.compact(summary.tokens))
                .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(BridgeTheme.codex)
                .accessibilityIdentifier("hub.account.tokens")
            Text("tokens · \(shortDate(fromDate))–\(shortDate(summary.days.last?.date ?? fromDate))")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            if !summary.isComplete || summary.overflow {
                Label(summary.overflow ? "Total too large to show" : "\(summary.recordedDays) of \(summary.days.count) days reported",
                      systemImage: "circle.dashed")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
                    .padding(.top, 4)
                    .help("Days OpenAI hasn't reported yet are left out, not counted as zero.")
                    .accessibilityIdentifier("hub.account.coverage")
            }
        }
    }

    private var historyStats: some View {
        let currentStreak = nonnegative(account.currentStreakDays)
        let longestStreak = nonnegative(account.longestStreakDays)
        let consistentStreak = currentStreak.flatMap { current in longestStreak.map { current <= $0 } } ?? true
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { statItems(currentStreak, longestStreak, consistentStreak, all: true) }
            HStack(spacing: 18) { statItems(currentStreak, longestStreak, consistentStreak, all: false) }
        }
    }

    @ViewBuilder
    private func statItems(_ current: Int?, _ longest: Int?, _ consistent: Bool, all: Bool) -> some View {
        historyStat(consistent ? current.map { "\($0) days" } : nil, "streak", "flame.fill", BridgeTheme.warning)
        historyStat(consistent ? longest.map { "\($0) days" } : nil, "best", "trophy.fill", BridgeTheme.claude)
        historyStat(nonnegative(account.peakDailyTokens).map { ActivityFormat.compact($0) }, "peak day", "bolt.fill", BridgeTheme.codex)
        if all {
            historyStat(nonnegative(account.lifetimeTokens).map { ActivityFormat.compact($0) }, "all time", "infinity", BridgeTheme.brand)
            historyStat(nonnegative(account.longestRunningTurnSeconds).map { ActivityFormat.duration(Double($0)) }, "longest request", "hourglass", BridgeTheme.gemini)
        }
    }

    private func historyStat(_ value: String?, _ label: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            Text(value ?? "—").font(BridgeFont.secondaryMedium.monospacedDigit()).foregroundStyle(BridgeTheme.textPrimary)
            Text(label).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func dailyChart(_ summary: ActivityAnalytics.AccountSummary) -> some View {
        let peak = summary.days.compactMap(\.tokens).max() ?? 0
        let upper = max(1, Double(peak) * 1.15)
        let tickLabels = axisLabels(summary.days)
        return Chart(summary.days) { day in
            if let tokens = day.tokens, tokens > 0 {
                BarMark(x: .value("Provider date", day.date), y: .value("Tokens", Double(tokens)))
                    .foregroundStyle(BridgeTheme.codex).cornerRadius(2)
                    .accessibilityLabel(day.date)
                    .accessibilityValue("\(tokens.formatted()) tokens")
            } else if day.tokens == 0 {
                PointMark(x: .value("Provider date", day.date), y: .value("Tokens", 0.0))
                    .foregroundStyle(BridgeTheme.codex).symbolSize(18)
                    .accessibilityLabel(day.date).accessibilityValue("Reported zero tokens")
            } else {
                PointMark(x: .value("Provider date", day.date), y: .value("Tokens", 0.0))
                    .symbol {
                        Image(systemName: day.conflicting ? "exclamationmark" : "xmark")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(day.conflicting ? BridgeTheme.warning : BridgeTheme.textSecondary)
                    }
                    .accessibilityLabel(day.date)
                    .accessibilityValue(day.conflicting ? "Conflicting readings; no total" : "Not reported")
            }
        }
        .chartXScale(domain: summary.days.map(\.date))
        .chartYScale(domain: 0...upper)
        .chartXAxis {
            AxisMarks(values: tickLabels) { value in
                AxisValueLabel {
                    if let label = value.as(String.self) { Text(shortDate(label)).font(BridgeFont.micro) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(BridgeTheme.separator)
                AxisValueLabel {
                    if let count = value.as(Double.self) {
                        Text(count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                            .font(BridgeFont.micro)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 112)
        .accessibilityLabel("Daily Codex tokens reported by OpenAI.")
        .accessibilityIdentifier("hub.account.dailyChart")
    }

    private func nonnegative(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }

    /// Use the same provider-label boundary as the selected daily chart.
    /// `now` is an instant, not a provider reporting-day definition.
    private var historyEnd: Date? {
        guard let exclusiveEnd = ActivityAnalytics.accountDate(toDate) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: -1, to: exclusiveEnd)
    }

    private func axisLabels(_ days: [ActivityAnalytics.AccountDay]) -> [String] {
        let step = max(1, Int(ceil(Double(days.count) / 7)))
        return days.enumerated().compactMap { index, day in index % step == 0 || index == days.count - 1 ? day.date : nil }
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = .current; formatter.setLocalizedDateFormatFromTemplate("dMMM")
        return formatter
    }()

    private func shortDate(_ label: String) -> String {
        guard let date = ActivityAnalytics.accountDate(label) else { return label }
        return Self.shortDateFormatter.string(from: date)
    }
}
