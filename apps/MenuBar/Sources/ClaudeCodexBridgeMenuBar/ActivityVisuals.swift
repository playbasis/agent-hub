import BridgeCore
import Charts
import SwiftUI

/// Formatting shared by every activity surface. Unknown stays "—", never 0.
enum ActivityFormat {
    static func duration(_ seconds: Double?, style: Style = .short) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
        guard let value = Int(exactly: seconds.rounded()) else { return "—" }
        let d = value / 86_400, h = (value % 86_400) / 3_600, m = (value % 3_600) / 60
        switch style {
        case .short:
            if d > 0 { return "\(d)d \(h)h" }
            if h > 0 { return "\(h)h \(m)m" }
            if m > 0 { return "\(m)m" }
            return "\(value)s"
        case .clock:
            if d > 0 { return "\(d)d \(h)h \(m)m" }
            return String(format: "%dh %02dm", h, m)
        }
    }

    enum Style { case short, clock }

    static func compact(_ number: Int?) -> String {
        guard let number else { return "—" }
        return number.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1)))
    }

    static func delta(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return nil }
        // Past +200% a percentage stops being readable; show a multiple.
        if value >= 2 { return "\((value + 1).formatted(.number.precision(.fractionLength(0))))×" }
        guard let percent = Int(exactly: (value * 100).rounded()) else { return nil }
        if percent == 0 { return "±0%" }
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }

    /// First sentence of a long goal objective, without markdown emphasis.
    static func headline(_ text: String, limit: Int = 110) -> String {
        // Codex's "read the attached objective file" preamble isn't the goal.
        if ActivityTitles.isCodexGoalWrapper(text) { return ActivityTitles.codexGoalTitle }
        let plain = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        let firstLine = plain.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? plain
        var sentence = firstLine
        if let end = firstLine.range(of: ". ") { sentence = String(firstLine[..<end.lowerBound]) + "." }
        if sentence.count > max(1, limit) { sentence = String(sentence.prefix(max(0, limit - 1))) + "…" }
        return sentence
    }

    static func project(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "Unattributed" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = now.timeIntervalSince(date)
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "Time unavailable" }
        if seconds < 60 { return "just now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    var values: [Double?]
    var tint: Color
    var height: CGFloat = 24

    var body: some View {
        let points = ActivityAnalytics.trend(values)
        Chart(points) { item in
            if let value = item.value {
                AreaMark(x: .value("i", item.id), y: .value("v", value), series: .value("Segment", item.segment))
                    .interpolationMethod(.linear)
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.25), tint.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("i", item.id), y: .value("v", value), series: .value("Segment", item.segment))
                    .interpolationMethod(.linear)
                    .foregroundStyle(tint)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round))
                // A one-day segment has no line. Dots retain that evidence
                // instead of making a perfectly valid receipt disappear.
                PointMark(x: .value("i", item.id), y: .value("v", value))
                    .foregroundStyle(tint)
                    .symbolSize(12)
            } else {
                // A stripe has no y-value: missing evidence is not zero usage.
                RuleMark(x: .value("i", item.id))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 2]))
                    .foregroundStyle(BridgeTheme.textTertiary.opacity(0.6))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0 ... max(points.compactMap(\.value).max() ?? 1, 1), range: .plotDimension(padding: 3))
        .chartXScale(domain: 0 ... max(values.count - 1, 1), range: .plotDimension(padding: 3))
        .chartLegend(.hidden)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - KPI tile

struct KPITile: View {
    var title: String
    var value: String
    var unit: String? = nil
    var delta: Double? = nil
    var deltaLabel: String = "vs previous"
    var series: [Double?] = []
    var tint: Color = BridgeTheme.codex
    var footnote: String? = nil
    var large = false
    var icon: String? = nil
    var info: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 7 : 6) {
            HStack(alignment: .center, spacing: 6) {
                if let icon {
                    Image(systemName: icon).font(.system(size: large ? 11 : 10, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: 14)
                }
                Text(title).font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                if let info { InfoButton(title: title, text: info) }
                Spacer(minLength: 4)
                DeltaChip(delta: delta, label: deltaLabel)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: large ? 26 : 19, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(BridgeTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                }
            }
            if series.count > 1 {
                // Dotted stripes inside the sparkline mark days without data.
                Sparkline(values: series, tint: tint, height: large ? 30 : 22)
            }
            if let footnote {
                Text(footnote).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: large ? 118 : nil, alignment: .topLeading)
        .bridgeCard(padding: large ? 14 : 11)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Plan meters

/// One provider's subscription windows as thin bars with a runway sentence.
struct PlanMeterRow: View {
    var name: String
    var agent: AgentName
    var estimate: QuotaEstimate?
    var now: Date
    var account: ProviderAccountStatus? = nil
    var onCreditRefresh: (() -> Void)? = nil
    var creditsRefreshing = false
    var onCreditVisibilityChanged: ((Bool) -> Void)? = nil
    var openCreditHistory: (() -> Void)? = nil

    private var tint: Color { BridgeTheme.color(for: agent) }
    private var readingState: ActivityPresentationPolicy.ReadingState { ActivityPresentationPolicy.quotaState(estimate, now: now) }
    private func remaining(_ window: QuotaWindow) -> Double? {
        guard ActivityPresentationPolicy.isCurrentWindow(window, now: now) else { return nil }
        return ActivityPresentationPolicy.remainingFraction(window)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            meterHeader
            meterWindows
            if agent == .codex { creditBalance }
        }
    }

    private var meterHeader: some View {
        HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(name).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                if let plan = estimate?.planName {
                    Text(plan.replacingOccurrences(of: "Claude ", with: "").replacingOccurrences(of: "ChatGPT ", with: ""))
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
                Spacer()
                if readingState == .stale {
                    Text("Out of date").font(BridgeFont.micro).foregroundStyle(BridgeTheme.warning)
                }
                if let window = primaryWindow, let fraction = remaining(window) {
                    Text("\(Int((fraction * 100).rounded()))% \(readingState == .fresh ? "left" : "last seen")")
                        .font(BridgeFont.captionMedium.monospacedDigit())
                        .foregroundStyle(color(for: window))
                } else {
                    Text(agent == .codex ? "Plan not reported" : "No reading").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                }
        }
    }

    @ViewBuilder private var meterWindows: some View {
        if let windows = estimate?.windows, !windows.isEmpty {
            ForEach(windows) { (window: QuotaWindow) in meterWindow(window) }
            runwayLine
        }
    }

    private func meterWindow(_ window: QuotaWindow) -> some View {
        HStack(spacing: 8) {
                        Text(shortLabel(window.label)).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                            .frame(width: 46, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.07))
                                if let fraction = remaining(window) {
                                    Capsule().fill(color(for: window))
                                        .frame(width: max(0, proxy.size.width * CGFloat(fraction)))
                                }
                            }
                        }
                        .frame(height: 5)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(name) \(window.label)")
                    .accessibilityValue(windowAccessibility(window))
    }

    private func windowAccessibility(_ window: QuotaWindow) -> String {
        guard let fraction = remaining(window) else { return "Current capacity unavailable" }
        let qualifier = readingState == .fresh ? "left" : "last seen; stale reading"
        return "\(Int((fraction * 100).rounded())) percent \(qualifier)"
    }

    private var creditBalance: CreditBalanceView {
        CreditBalanceView(estimate: estimate, account: account, now: now, compact: true,
            onRefresh: onCreditRefresh, refreshing: creditsRefreshing, onVisibilityChanged: onCreditVisibilityChanged,
            openHistory: openCreditHistory)
    }

    private var primaryWindow: QuotaWindow? {
        estimate?.windows.filter { ActivityPresentationPolicy.isCurrentWindow($0, now: now) }.max { $0.usedRatio < $1.usedRatio }
    }

    private func shortLabel(_ label: String) -> String {
        if label.lowercased().contains("5-hour") { return "5 hour" }
        if label.lowercased().contains("weekly") || label.lowercased().contains("7-day") {
            return label.contains("·") && !label.lowercased().contains("all") ? "Model" : "Weekly"
        }
        return label
    }

    private func color(for window: QuotaWindow) -> Color {
        if readingState != .fresh || remaining(window) == nil { return BridgeTheme.textTertiary }
        if window.usedRatio >= 0.9 { return BridgeTheme.danger }
        if window.usedRatio >= 0.75 { return BridgeTheme.warning }
        return tint
    }

    private enum Runway { case text(String), warn(String), alert(String), none }

    private var runway: Runway {
        guard let window = primaryWindow else {
            return estimate?.windows.isEmpty == false ? .text("Refresh for the current plan limits.") : .none
        }
        guard readingState == .fresh else {
            return .text("Last checked \(ActivityFormat.relative(estimate?.fetchedAt, now: now)). Refresh for current limits.")
        }
        if let reset = window.resetAt, reset <= now { return .text("Limit has reset. Refresh to see the new window.") }
        if window.usedRatio >= 1 {
            if agent == .codex { return .text("Included allowance used up. Credit balance shown below.") }
            return .alert(window.resetAt == nil ? "Limit reached. Reset time wasn't reported." : "Limit reached. It resets \(resetPhrase(window))")
        }
        switch ActivityPresentationPolicy.runway(window, estimate: estimate, now: now) {
        case let .exhausts(date):
            if date <= now { return .alert("May already be used up. Refresh to check.") }
            let message = "Could run out \(when(date))"
            return date.timeIntervalSince(now) < 86_400 ? .alert(message) : .warn(message)
        case let .lastsUntilReset(reset):
            return .text("On pace to last until it resets \(when(reset)).")
        case .unknown:
            if window.resetAt != nil { return .text("Resets \(resetPhrase(window))") }
            return .text("No reset time shared, so no forecast.")
        }
    }

    private var isAlert: Bool { if case .alert = runway { return true } else { return false } }

    /// "5d 22h before it resets · 64% left" under a pace warning.
    private var runwayDetail: String? {
        guard let window = primaryWindow, let reset = window.resetAt,
              case let .exhausts(date) = ActivityPresentationPolicy.runway(window, estimate: estimate, now: now), date > now,
              let left = remaining(window) else { return nil }
        return "\(ActivityFormat.duration(reset.timeIntervalSince(date))) before it resets · \(Int((left * 100).rounded()))% left"
    }

    private func when(_ date: Date) -> String {
        var calendar = Calendar.current
        calendar.timeZone = ActivityAnalytics.reportingTimeZone
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(date.formatted(.dateTime.hour().minute()))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(date.formatted(.dateTime.hour().minute()))"
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    private func resetPhrase(_ window: QuotaWindow) -> String {
        guard let reset = window.resetAt else { return "later." }
        return "\(when(reset))."
    }

    @ViewBuilder private var runwayLine: some View {
        switch runway {
        case let .text(text):
            Text(text).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        case let .warn(text), let .alert(text):
            CalloutBanner(tone: isAlert ? .alert : .warning, title: text, detail: runwayDetail,
                          note: "Forecast from your average pace since the limit last reset.", compact: true)
        case .none:
            EmptyView()
        }
    }
}

// MARK: - Work mix

/// Horizontal 100% bar of observed tool categories with a compact legend.
struct WorkMixBar: View {
    var shares: [ActivityAnalytics.Share]
    var maxLegend = 4
    /// Thinner bar and tighter spacing for dense cards.
    var compact = false

    private var total: Double { max(1, shares.reduce(0.0) { $0 + Double(max(0, $1.value)) }) }
    private var names: [String] { shares.map(\.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 8) {
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(shares) { share in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(BridgeTheme.category(share.name, in: names))
                            .frame(width: max(0, (proxy.size.width - CGFloat(max(0, shares.count - 1)) * 2) * CGFloat(max(0, share.value)) / CGFloat(total)))
                            .help("\(share.name): \(share.value) tool calls")
                    }
                }
            }
            .frame(height: compact ? 5 : 8)
            .clipShape(Capsule())
            HStack(spacing: 10) {
                ForEach(Array(shares.prefix(maxLegend))) { share in
                    HStack(spacing: 4) {
                        Circle().fill(BridgeTheme.category(share.name, in: names)).frame(width: 6, height: 6)
                        Text(share.name).foregroundStyle(BridgeTheme.textSecondary)
                        Text("\(Int((Double(max(0, share.value)) / total * 100).rounded()))%")
                            .foregroundStyle(BridgeTheme.textTertiary).monospacedDigit()
                    }
                    .lineLimit(1)
                }
            }
            .font(BridgeFont.micro)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Work mix")
        .accessibilityValue(shares.map { "\($0.name) \(Int((Double(max(0, $0.value)) / total * 100).rounded())) percent" }.joined(separator: ", "))
    }
}

// MARK: - Goal swimlane

/// Wall-clock lanes for a goal's session and its child agents. Bars are
/// recorded intervals; dots are starts without a recorded end. Drawn directly
/// rather than with Swift Charts so the label column and rows align exactly.
struct GoalSwimlane: View {
    var lanes: [ActivityAnalytics.Lane]
    var from: Date
    var to: Date
    var maxLanes: Int
    var laneHeight: CGFloat = 14
    var showLabels = true
    var labelWidth: CGFloat = 160

    private var shown: [ActivityAnalytics.Lane] { Array(lanes.prefix(max(0, maxLanes))) }
    private var span: TimeInterval {
        let value = to.timeIntervalSince(from)
        return value.isFinite && value > 0 ? value : 1
    }
    private let axisHeight: CGFloat = 16

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showLabels {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(shown) { lane in
                        Text(lane.isParent ? "Goal session" : lane.title)
                            .font(BridgeFont.micro)
                            .foregroundStyle(lane.isParent ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
                            .lineLimit(1).truncationMode(.tail)
                            .frame(width: labelWidth, height: laneHeight, alignment: .trailing)
                            .help(lane.title)
                    }
                }
            }
            VStack(spacing: 2) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .topLeading) {
                        ForEach(ticks, id: \.self) { tick in
                            Rectangle().fill(Color.white.opacity(0.05))
                                .frame(width: 1, height: proxy.size.height)
                                .offset(x: x(tick, width))
                        }
                        ForEach(Array(shown.enumerated()), id: \.element.id) { row, lane in
                            let color = BridgeTheme.color(for: lane.provider).opacity(lane.isParent ? 1 : 0.75)
                            let barHeight = max(3, laneHeight * 0.58)
                            let y = CGFloat(row) * laneHeight + (laneHeight - barHeight) / 2
                            Rectangle().fill(Color.white.opacity(row.isMultiple(of: 2) ? 0.025 : 0))
                                .frame(width: width, height: laneHeight)
                                .offset(y: CGFloat(row) * laneHeight)
                            ForEach(Array(lane.intervals.enumerated()), id: \.offset) { _, interval in
                                let start = x(interval.start, width)
                                RoundedRectangle(cornerRadius: min(2, barHeight / 2), style: .continuous)
                                    .fill(color)
                                    .frame(width: max(1.5, x(interval.end, width) - start), height: barHeight)
                                    .offset(x: start, y: y)
                            }
                            ForEach(Array(lane.openStarts.enumerated()), id: \.offset) { _, time in
                                Circle().strokeBorder(color, lineWidth: 1.2)
                                    .frame(width: barHeight + 1, height: barHeight + 1)
                                    .offset(x: x(time, width) - (barHeight + 1) / 2, y: y - 0.5)
                            }
                        }
                        let clock = Date()
                        let now = min(clock, to)
                        if now > from && clock.timeIntervalSince(to) <= 60 {
                            Rectangle().fill(Color.white.opacity(0.3))
                                .frame(width: 1, height: proxy.size.height)
                                .offset(x: x(now, width))
                        }
                    }
                }
                .frame(height: CGFloat(max(shown.count, 1)) * laneHeight)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ForEach(ticks, id: \.self) { tick in
                            Text(label(tick))
                                .font(.system(size: 9).monospacedDigit())
                                .foregroundStyle(BridgeTheme.textTertiary)
                                .fixedSize()
                                .offset(x: x(tick, proxy.size.width) - 12)
                        }
                    }
                }
                .frame(height: axisHeight)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent timeline")
        .accessibilityValue("\(lanes.count) lanes, \(lanes.reduce(0) { $0 + $1.intervals.count }) recorded work intervals")
    }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        let fraction = date.timeIntervalSince(from) / span
        return fraction.isFinite ? CGFloat(min(max(fraction, 0), 1)) * max(0, width) : 0
    }

    /// Round tick times: hourly steps chosen so roughly four labels fit.
    private var ticks: [Date] {
        guard to > from, to.timeIntervalSince(from).isFinite else { return [] }
        let hours = span / 3_600
        let step: Double = hours <= 8 ? 3_600 * max(1, (hours / 4).rounded(.down))
            : hours <= 30 ? 6 * 3_600
            : hours <= 80 ? 12 * 3_600
            : 24 * 3_600 * max(1, (hours / 24 / 5).rounded(.up))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ActivityAnalytics.reportingTimeZone
        let base = calendar.startOfDay(for: from)
        var tick = base
        var result: [Date] = []
        var attempts = 0
        while tick <= to && attempts < 32 {
            if tick > from.addingTimeInterval(span * 0.04), tick < to.addingTimeInterval(-span * 0.04) { result.append(tick) }
            tick = tick.addingTimeInterval(step)
            attempts += 1
        }
        return result
    }

    private func label(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = ActivityAnalytics.reportingTimeZone
        formatter.setLocalizedDateFormatFromTemplate(span > 36 * 3_600 ? "EEE HH" : "HH:mm")
        return formatter.string(from: date)
    }
}

/// Number of agents with a recorded interval covering each moment.
struct ConcurrencyChart: View {
    var points: [ActivityAnalytics.ConcurrencyPoint]
    var tint: Color = BridgeTheme.codex
    var height: CGFloat = 56

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.time), y: .value("Agents", point.agents))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.45), tint.opacity(0.05)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", point.time), y: .value("Agents", point.agents))
                .interpolationMethod(.stepEnd)
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.2))
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel().font(BridgeFont.micro)
            }
        }
        .frame(height: height)
        .accessibilityLabel("Concurrent agents over time")
        .accessibilityValue("Peak \(points.map(\.agents).max() ?? 0) agents")
    }
}

// MARK: - WorkspaceOps-style swimlanes

enum SwimGroup: String, CaseIterable, Identifiable {
    case none = "None", role = "Role", load = "Load"
    var id: String { rawValue }
}

/// One visible timeline's pixel layouts and labels. Bounds prevent an
/// intentional "show all" or continuous resize from retaining old layouts.
final class SwimlanePresentationCache {
    struct PresentedChip: Identifiable {
        var chip: ActivityTimelineLayout.Chip
        var category: String?
        var help: String
        var id: String { chip.id }
    }
    private struct Context: Equatable { var revision: UInt64; var from: Date; var to: Date }
    private struct Entry { var width: Double; var chips: [PresentedChip]; var cost: Int }
    private struct LabelKey: Hashable { var date: Date; var template: String; var locale: String; var zone: String }
    private var context: Context?
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var labels: [LabelKey: String] = [:]
    private var formatters: [String: DateFormatter] = [:]
    private let maximumLanes: Int
    private let maximumSegments: Int
    private(set) var layoutBuildCount = 0
    var retainedLaneCount: Int { entries.count }
    var retainedSegmentCount: Int { entries.values.reduce(0) { $0 + $1.cost } }
    var retainedLabelCount: Int { labels.count }
    var retainedFormatterCount: Int { formatters.count }

    init(maximumLanes: Int = 64, maximumSegments: Int = 20_000) {
        self.maximumLanes = max(1, maximumLanes); self.maximumSegments = max(1, maximumSegments)
    }

    func chips(lane: ActivityAnalytics.Lane, revision: UInt64, from: Date, to: Date, width: Double,
               help: (ActivityTimelineLayout.Chip) -> String) -> [PresentedChip] {
        guard width.isFinite, width > 0 else { return [] }
        let incoming = Context(revision: revision, from: from, to: to)
        if context != incoming { entries.removeAll(); order.removeAll(); context = incoming }
        // Ignore sub-pixel geometry noise without turning resize into an
        // unbounded dictionary of near-identical layouts.
        let width = (min(width, 1_000_000) * 64).rounded(.down) / 64
        if let entry = entries[lane.id], entry.width == width {
            order.removeAll { $0 == lane.id }; order.append(lane.id)
            return entry.chips
        }
        let result = ActivityTimelineLayout.chips(lane.segments, from: from, to: to, width: width).map {
            PresentedChip(chip: $0, category: $0.category, help: help($0))
        }
        layoutBuildCount += 1
        let cost = result.reduce(0) { $0 + $1.chip.segments.count }
        entries.removeValue(forKey: lane.id); order.removeAll { $0 == lane.id }
        if cost <= maximumSegments {
            while !order.isEmpty && (entries.count >= maximumLanes || retainedSegmentCount > maximumSegments - cost) {
                entries.removeValue(forKey: order.removeFirst())
            }
            entries[lane.id] = Entry(width: width, chips: result, cost: cost); order.append(lane.id)
        }
        return result
    }

    func label(_ date: Date, template: String) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return "Time unavailable" }
        let locale = Locale.current.identifier
        let zone = ActivityAnalytics.reportingTimeZone
        let key = LabelKey(date: date, template: template, locale: locale, zone: zone.identifier)
        if let value = labels[key] { return value }
        let formatterKey = template + "|" + locale + "|" + zone.identifier
        let formatter: DateFormatter
        if let existing = formatters[formatterKey] { formatter = existing }
        else {
            if formatters.count >= 8 { formatters.removeAll(); labels.removeAll() }
            formatter = DateFormatter(); formatter.locale = Locale(identifier: locale); formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate(template); formatters[formatterKey] = formatter
        }
        let result = formatter.string(from: date)
        if labels.count >= 512 { labels.removeAll() }
        labels[key] = result
        return result
    }

    func reset() { context = nil; entries.removeAll(); order.removeAll(); labels.removeAll(); formatters.removeAll() }
}

/// Agent swimlanes modelled on the WorkspaceOps calendar: a portrait label
/// cell per agent, a 15-minute load track, category-coloured chips with a
/// solid leading accent, and ◆ N cluster chips where turns are too dense to
/// draw individually. Only recorded intervals are drawn; open starts are
/// hollow markers.
struct WorkSwimlanes: View {
    var lanes: [ActivityAnalytics.Lane]
    var overview: ActivityOverview
    var from: Date
    var to: Date
    var now: Date
    var group: SwimGroup
    var maxRows = 24
    var preparedAssignments: [String: AgentPersonaCatalog.Assignment]? = nil
    var preparedLoad: [ActivityAnalytics.LoadBucket]? = nil
    var snapshotRevision: UInt64 = 0
    var select: (String) -> Void = { _ in }

    @State private var showAll = false
    @State private var presentationCache = SwimlanePresentationCache()
    @Environment(\.inspectedTurn) private var inspectedTurn
    @AppStorage("bridge.showPersonas") private var showPersonas = true
    /// Roomy enough for a portrait and two lines of text without crowding.
    private let labelWidth: CGFloat = 236
    private let rowHeight: CGFloat = 42
    private let chipHeight: CGFloat = 24
    private var span: TimeInterval {
        let value = to.timeIntervalSince(from)
        return value.isFinite && value > 0 ? value : 1
    }

    private struct Row: Identifiable {
        var lane: ActivityAnalytics.Lane
        var assignment: AgentPersonaCatalog.Assignment?
        var id: String { lane.id }
    }

    private struct Section: Identifiable {
        var title: String?
        var icon: String?
        var rows: [Row]
        var id: String { title ?? "all" }
    }

    var body: some View {
        let assignments = preparedAssignments ?? PersonaDirectory.assignments(for: overview)
        let rows = lanes.map { Row(lane: $0, assignment: assignments[$0.id]) }
        let visible = showAll ? rows : Array(rows.prefix(max(0, maxRows)))
        let groups = sections(visible)
        let headerCount = groups.filter { $0.title != nil }.count
        // Leave native horizontal-scroller room at narrow widths; it must
        // never cover the last agent or the Show all button.
        let rowSpace: CGFloat = CGFloat(visible.count) * rowHeight
        let headingSpace: CGFloat = CGFloat(headerCount) * 28
        let expansionSpace: CGFloat = rows.count > maxRows ? 40 : 0
        let height: CGFloat = 106 + rowSpace + headingSpace + expansionSpace
        return GeometryReader { proxy in
            ScrollView(.horizontal) {
                contents(rows: rows, groups: groups).frame(width: max(560, proxy.size.width))
            }
        }
        .frame(height: height)
        .onDisappear { presentationCache.reset() }
    }

    private func contents(rows: [Row], groups: [Section]) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            header(count: lanes.count)
            loadTrack
            ForEach(groups) { section in
                if let title = section.title {
                    HStack(spacing: 6) {
                        if let icon = section.icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
                        Text("\(title.uppercased()) · \(section.rows.count)").font(.system(size: 9.5, weight: .bold)).tracking(0.7)
                        Spacer()
                    }
                    .foregroundStyle(BridgeTheme.textTertiary)
                    .padding(.horizontal, 10).frame(height: 28, alignment: .bottom)
                }
                ForEach(section.rows) { row in rowView(row) }
            }
            if rows.count > maxRows {
                Button(showAll ? "Show fewer" : "Show all \(rows.count) agents") {
                    withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.2)) { showAll.toggle() }
                }
                .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
                .padding(.horizontal, 10).frame(height: 40)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(BridgeTheme.wellBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sections(_ rows: [Row]) -> [Section] {
        switch group {
        case .none:
            return [Section(title: nil, icon: nil, rows: rows)]
        case .role:
            return AgentRole.allCases.compactMap { role in
                let matching = rows.filter { ($0.assignment?.role ?? .specialist) == role }
                return matching.isEmpty ? nil : Section(title: role.title, icon: role.symbol, rows: matching)
            }
        case .load:
            let buckets: [(String, String, (Double) -> Bool)] = [
                ("High load", "flame", { $0 >= 7_200 }),
                ("Medium load", "gauge.with.dots.needle.50percent", { $0 >= 1_800 && $0 < 7_200 }),
                ("Low load", "leaf", { $0 < 1_800 }),
            ]
            return buckets.compactMap { title, icon, test in
                let matching = rows.filter { test($0.lane.busySeconds) }
                return matching.isEmpty ? nil : Section(title: title, icon: icon, rows: matching)
            }
        }
    }

    // MARK: Header & load

    private func header(count: Int) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text("AGENTS · \(count)").font(.system(size: 9.5, weight: .bold)).tracking(0.7).foregroundStyle(BridgeTheme.textTertiary)
                Text(rangeLabel).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
            }
            .padding(.leading, 14)
            .frame(width: labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    ForEach(ticks, id: \.self) { tick in
                        Text(tickLabel(tick)).font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(BridgeTheme.textTertiary).fixedSize()
                            .offset(x: x(tick, proxy.size.width) - 14, y: 14)
                    }
                    if now > from, now <= to {
                        Text("now").font(.system(size: 9, weight: .bold)).foregroundStyle(BridgeTheme.success).fixedSize()
                            .offset(x: x(now, proxy.size.width) - 9, y: 0)
                    }
                }
            }
            .padding(.trailing, 10)
        }
        .frame(height: 38)
        .padding(.top, 8)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private var loadTrack: some View {
        let buckets = preparedLoad ?? ActivityAnalytics.load(lanes, from: from, to: to, bucketSeconds: 900)
        let measured = !buckets.isEmpty && lanes.contains { !$0.intervals.isEmpty }
        let peak = max(1, buckets.map(\.meanAgents).max() ?? 1)
        return HStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 9, weight: .semibold))
                Text("15-MIN AVG").font(.system(size: 9.5, weight: .bold)).tracking(0.7)
                Text(measured ? String(format: "max %.1f", buckets.map(\.meanAgents).max() ?? 0) : "—")
                    .font(.system(size: 9.5).monospacedDigit())
            }
            .foregroundStyle(BridgeTheme.textTertiary)
            .help("Highest 15-minute average from recorded intervals, not the exact peak number of simultaneous agents.")
            .padding(.leading, 14)
            .frame(width: labelWidth, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .bottomLeading) {
                    if measured {
                        ForEach(buckets) { bucket in
                            let ratio = min(1, max(0, bucket.meanAgents / peak))
                            let left = x(bucket.start, proxy.size.width)
                            let width = max(0, x(bucket.end, proxy.size.width) - left)
                            RoundedRectangle(cornerRadius: 1)
                                .fill(BridgeTheme.codex.opacity(0.15 + 0.85 * ratio))
                                .frame(width: max(0, width - min(1, width)), height: bucket.meanAgents > 0 ? 3 + CGFloat(ratio) * max(0, proxy.size.height - 6) : 2)
                                .offset(x: left)
                                .help(String(format: "%@–%@ · %.1f agents working on average", timeLabel(bucket.start), timeLabel(bucket.end), bucket.meanAgents))
                        }
                    } else {
                        Text(buckets.isEmpty ? "Load unavailable for this range" : "Closed-interval evidence unavailable")
                            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
            }
            .padding(.trailing, 10)
        }
        .frame(height: 36)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: Rows

    private func rowView(_ row: Row) -> some View {
        let lane = row.lane
        let recent = ActivityPresentationPolicy.isRecent(lane.lastActivity, now: now)
        return HStack(spacing: 0) {
            Button { inspect(lane.id, turnID: lane.segments.max { $0.start < $1.start }?.turnID) } label: {
                HStack(spacing: 10) {
                    AgentPortrait(persona: row.assignment?.persona, provider: lane.provider, size: 26, recent: recent, showBadge: false)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(lane.isParent ? "Goal session" : lane.title)
                            .font(.system(size: 12, weight: lane.isParent ? .semibold : .medium))
                            .foregroundStyle(BridgeTheme.textPrimary).lineLimit(1).truncationMode(.tail)
                        Text("\(lane.turnCount) \(lane.turnCount == 1 ? "request" : "requests") · \(ActivityFormat.duration(lane.busySeconds))")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                .padding(.leading, 14)
                .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(personaHelp(row) + "\nClick to inspect this agent's latest turn")
            .contextMenu {
                Button("Inspect latest turn") { inspect(lane.id, turnID: lane.segments.max { $0.start < $1.start }?.turnID) }
                Button("Open goal replay") { openReplay(lane.id) }
                Button("Session details") { select(lane.id) }
            }
            GeometryReader { proxy in
                track(lane, width: proxy.size.width)
            }
            .frame(height: rowHeight)
            .padding(.trailing, 10)
        }
        .background(lane.isParent ? Color.white.opacity(0.035) : Color.clear)
        .overlay(alignment: .bottom) { Rectangle().fill(BridgeTheme.separator.opacity(0.6)).frame(height: 0.5) }
    }

    private func personaHelp(_ row: Row) -> String {
        var parts = [row.lane.title]
        if let model = row.lane.model { parts.append(model) }
        if let assignment = row.assignment {
            parts.append("\(assignment.role.title) — \(assignment.role.explanation)")
            if showPersonas, let persona = assignment.persona { parts.append("Persona: \(persona.fullName) (decorative)") }
        }
        return parts.joined(separator: "\n")
    }

    @ViewBuilder
    private func track(_ lane: ActivityAnalytics.Lane, width: CGFloat) -> some View {
        let presentedChips: [SwimlanePresentationCache.PresentedChip] = presentationCache.chips(lane: lane,
            revision: snapshotRevision, from: from, to: to, width: Double(width), help: { chipHelp($0, lane: lane) })
        ZStack(alignment: .leading) {
            ForEach(ticks, id: \.self) { tick in
                Rectangle().fill(Color.white.opacity(0.045)).frame(width: 1, height: rowHeight).offset(x: x(tick, width)).allowsHitTesting(false)
            }
            ForEach(presentedChips) { presented in
                let chip = presented.chip
                let color = presented.category.map { BridgeTheme.category($0) } ?? BridgeTheme.color(for: lane.provider)
                let chipWidth = CGFloat(max(0, chip.x1 - chip.x0))
                let inspected = inspectedTurn.map { focus in focus.sessionID == lane.id && chip.segments.contains { $0.turnID == focus.turnID } } ?? false
                Button { inspect(lane.id, turnID: chip.segments.first?.turnID) } label: {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(color.opacity(chip.isCluster ? 0.32 : 0.24))
                    Rectangle().fill(color).frame(width: min(2, chipWidth))
                    if chip.isCluster, chipWidth >= 32 {
                        Text("◆ \(chip.segments.count)").font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(BridgeTheme.textPrimary).padding(.leading, 5).lineLimit(1)
                    } else if !chip.isCluster, chipWidth >= 26, let category = presented.category {
                        Image(systemName: BridgeTheme.categorySymbol(category)).font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(BridgeTheme.textPrimary.opacity(0.85)).padding(.leading, 5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(BridgeTheme.brand, lineWidth: inspected ? 1.5 : 0))
                .shadow(color: BridgeTheme.brand.opacity(inspected ? 0.45 : 0), radius: 4)
                .frame(width: max(3, chipWidth), height: chipHeight)
                .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Offset the whole button, not just its artwork. Gesture
                // regions used to stay at the track's origin for thin chips.
                .offset(x: CGFloat(chip.x0))
                .help(presented.help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(presented.help)
                .accessibilityHint("Inspect this turn's steps, tools and results")
                .accessibilityAddTraits(inspected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("bridge.swimlane.block.\(lane.id).\(presented.id)")
                .contextMenu {
                    Button("Inspect turn") { inspect(lane.id, turnID: chip.segments.first?.turnID) }
                    Button("Open goal replay") { openReplay(lane.id, turnIDs: chip.segments.map(\.turnID)) }
                }
            }
            ForEach(Array(lane.openStarts.enumerated()), id: \.offset) { _, start in
                Button { inspect(lane.id, turnID: openTurnID(lane.id, start: start)) } label: {
                    Circle().strokeBorder(BridgeTheme.color(for: lane.provider), lineWidth: 1.4)
                        .frame(width: 8, height: 8).padding(3).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .offset(x: x(start, width) - 4)
                    .help("Started \(timeLabel(start)) · end not recorded. Click to inspect.")
                    .accessibilityLabel("Inspect open recorded work")
            }
            if now > from, now <= to {
                Rectangle().fill(BridgeTheme.success.opacity(0.6)).frame(width: 1, height: rowHeight).offset(x: x(now, width)).allowsHitTesting(false)
            }
        }
        .frame(width: width, height: rowHeight, alignment: .leading)
        .clipped()
    }

    private func inspect(_ sessionID: String, turnID: String?) {
        Task { @MainActor in
            ActivityReportsController.shared.inspectTurn(overview: overview, sessionID: sessionID, turnID: turnID, snapshotRevision: snapshotRevision)
        }
    }

    /// The turn behind an open-start marker: the one that started then.
    private func openTurnID(_ sessionID: String, start: Date) -> String? {
        overview.sessions.first { $0.id == sessionID }?.turns.first { $0.startedAt == start && $0.completedAt == nil }?.id
    }

    private func openReplay(_ sessionID: String, turnIDs: [String] = []) {
        Task { @MainActor in
            ActivityReportsController.shared.openReplay(overview: overview, sessionID: sessionID, focusTurnIDs: turnIDs)
        }
    }

    private func chipHelp(_ chip: ActivityTimelineLayout.Chip, lane: ActivityAnalytics.Lane) -> String {
        guard let first = chip.segments.first else { return "No saved native records" }
        let last = chip.segments.map(\.end).max() ?? first.end
        let time = "\(timeLabel(first.start))–\(timeLabel(last))"
        var counts: [String: Int] = [:]
        for segment in chip.segments { counts[segment.category ?? "Tools not recorded", default: 0] += 1 }
        let breakdown = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        let head = chip.isCluster ? "\(chip.segments.count) saved native records" : "1 saved native record"
        let tools = ActivityMetrics.knownTotal(chip.segments.map(\.measuredToolCalls))
        return "\(lane.isParent ? "Goal session" : lane.title)\n\(head) · \(time) · \(ActivityFormat.duration(chip.recordedSeconds)) recorded interval\n\(breakdown)\n\(tools.map { "\($0) source-record tool calls (not prorated to the clipped timeline)" } ?? "Tool calls not recorded")"
    }

    // MARK: Time axis

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        let fraction = date.timeIntervalSince(from) / span
        return fraction.isFinite && width.isFinite ? CGFloat(min(max(fraction, 0), 1)) * max(0, width) : 0
    }

    private var ticks: [Date] {
        guard to > from, to.timeIntervalSince(from).isFinite else { return [] }
        let hours = span / 3_600
        let step: Double = hours <= 8 ? 3_600 : hours <= 30 ? 3 * 3_600 : hours <= 80 ? 12 * 3_600 : 24 * 3_600 * max(1, (hours / 24 / 6).rounded(.up))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ActivityAnalytics.reportingTimeZone
        var tick = calendar.startOfDay(for: from)
        var result: [Date] = []
        var attempts = 0
        while tick <= to && attempts < 128 {
            if tick > from.addingTimeInterval(span * 0.03), tick < to.addingTimeInterval(-span * 0.03) { result.append(tick) }
            tick = tick.addingTimeInterval(step)
            attempts += 1
        }
        return result
    }

    private func tickLabel(_ date: Date) -> String {
        presentationCache.label(date, template: span > 36 * 3_600 ? "EEE d" : "HH:mm")
    }

    private var rangeLabel: String {
        guard let hours = Int(exactly: (span / 3_600).rounded()) else { return "Range unavailable" }
        return span > 36 * 3_600 ? "\(presentationCache.label(from, template: "EEE d MMM HH:mm")) →" : "Last \(hours) hours"
    }

    private func timeLabel(_ date: Date) -> String {
        presentationCache.label(date, template: span > 86_400 ? "dMMM HH:mm" : "HH:mm")
    }
}
