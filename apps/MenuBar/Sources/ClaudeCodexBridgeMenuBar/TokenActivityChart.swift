import BridgeCore
import Charts
import SwiftUI

/// A compact view of the same frozen, normalized receipts as Models and the
/// metrics API. Subscription capacity remains a separate provider-owned gauge.
struct TokenActivityChart: View {
    var snapshot: TokenSeriesSnapshot
    var isBusy: Bool
    var isReady: Bool
    var onRefresh: () -> Void

    @State private var bucket: TokenBucketSize = .hour
    @State private var metric: Metric = .total

    enum Metric: String, CaseIterable, Identifiable {
        case total = "Tokens", output = "Output", weighted = "Adjusted"
        var id: String { rawValue }
        var acceptanceID: String {
            switch self { case .total: return "total"; case .output: return "output"; case .weighted: return "weighted" }
        }

        func value(_ usage: ActivityAccounting.UsageTotals) -> Double? {
            let result: Double?
            switch self {
            case .total: result = usage.tokensKnown.map(Double.init)
            case .output: result = usage.outputKnown.map(Double.init)
            case .weighted: result = usage.weightedEquivalent
            }
            return result.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        func isPartial(_ usage: ActivityAccounting.UsageTotals) -> Bool {
            self == .output ? usage.outputIsPartial : usage.tokensArePartial
        }
        func value(in point: TokenSeriesPoint, agent: String, canonical: Bool) -> Double? {
            if canonical { return point.authoritativeByAgent?[agent].flatMap { value($0) } }
            return point.byAgent[agent].flatMap { legacyValue($0) }
        }
        func legacyValue(_ parts: TokenComponents) -> Double? {
            guard [parts.freshInput, parts.cacheRead, parts.cacheWrite, parts.output].allSatisfy({ $0 >= 0 }) else { return nil }
            switch self {
            case .total:
                return ActivityMetrics.knownTotal([parts.freshInput, parts.cacheRead, parts.cacheWrite, parts.output]).map(Double.init)
            case .output: return Double(parts.output)
            case .weighted:
                let result = Double(parts.freshInput) + Double(parts.cacheRead) * 0.1 + Double(parts.cacheWrite) * 1.25 + Double(parts.output) * 5
                return result.isFinite ? result : nil
            }
        }
        var explanation: String {
            switch self {
            case .total: return "Known token totals from saved usage receipts; cached and reasoning subsets are not counted twice."
            case .output: return "Known output tokens. These may include reasoning tokens; token volume is not a measure of code quality."
            case .weighted: return "A comparison heuristic, not a price: fresh input ×1, repeated context ×0.1, cache writes ×1.25, output ×5. Available only when the breakdown reconciles."
            }
        }
    }

    struct AcceptanceSelection {
        var bucket: TokenBucketSize
        var metric: Metric
        var supported: Bool
        var state: [String: String] { ["bucket": bucket.rawValue, "metric": metric.acceptanceID] }
    }
    static func acceptanceResponse(name: String?, value: String?, scope: String, active: Bool,
                                   bucket: TokenBucketSize, metric: Metric) -> AcceptanceSelection? {
        guard active, scope == "panel-chart" else { return nil }
        var result = AcceptanceSelection(bucket: bucket, metric: metric, supported: true)
        switch name {
        case "chart.window":
            switch value { case "hour": result.bucket = .hour; case "day": result.bucket = .day; default: result.supported = false }
        case "chart.metric":
            switch value { case "output": result.metric = .output; case "total": result.metric = .total; case "weighted": result.metric = .weighted; default: result.supported = false }
        case "report": break
        default: result.supported = false
        }
        return result
    }

    private struct Row: Identifiable {
        var id: String { "\(agent)-\(start.timeIntervalSince1970)" }
        var start: Date
        var end: Date
        var agent: String
        var label: String
        var value: Double
        var partial: Bool
        var lower: Double
        var upper: Double
        var barStart: Date { start.addingTimeInterval(end.timeIntervalSince(start) * 0.05) }
        var barEnd: Date { end.addingTimeInterval(-end.timeIntervalSince(start) * 0.05) }
    }
    private var series: TokenSeries { bucket == .hour ? snapshot.hourly : snapshot.daily }
    private static let agentOrder = ["claude", "codex", "grok"]
    private static func label(_ agent: String) -> String {
        switch agent { case "claude": return "Claude"; case "codex": return "Codex"; case "grok": return "Grok"; default: return "Other" }
    }
    private static func ordered(_ keys: [String]) -> [String] {
        keys.sorted { lhs, rhs in
            let a = agentOrder.firstIndex(of: lhs) ?? Int.max, b = agentOrder.firstIndex(of: rhs) ?? Int.max
            return a == b ? lhs < rhs : a < b
        }
    }
    private var rows: [Row] {
        series.points.flatMap { point in
            let canonical = snapshot.accountingSchemaVersion != nil
            let keys = canonical ? point.authoritativeByAgent.map { Array($0.keys) } ?? [] : Array(point.byAgent.keys)
            let ordered = Self.ordered(keys)
            let values = ordered.map { metric.value(in:point,agent:$0,canonical:canonical) }
            let ranges = Self.stackRanges(values)
            return ordered.enumerated().compactMap { index, agent -> Row? in
                let usage = point.authoritativeByAgent?[agent]
                guard let value = values[index], let range = ranges[index] else { return nil }
                guard let end = point.end ?? (canonical ? nil : point.start.addingTimeInterval(bucket == .hour ? 3_600 : 86_400)) else { return nil }
                guard end > point.start else { return nil }
                return Row(start: point.start, end: end, agent: agent, label: Self.label(agent), value: value,
                           partial: usage.map { metric.isPartial($0) } ?? false, lower: range.lower, upper: range.upper)
            }
        }
    }
    struct StackRange: Equatable { var lower:Double; var upper:Double }
    static func stackRanges(_ values:[Double?]) -> [StackRange?] {
        var base = 0.0
        return values.map { value in
            guard let value, value.isFinite, value >= 0 else { return nil }
            let top = base + value
            guard top.isFinite else { return nil }
            defer { base = top }
            return StackRange(lower:base,upper:top)
        }
    }
    private var windowValue: Double? {
        if snapshot.accountingSchemaVersion != nil { return series.authoritativeTotals.flatMap { metric.value($0) } }
        let values = series.points.flatMap { $0.byAgent.values }.compactMap { metric.legacyValue($0) }
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0, +)
        return total.isFinite ? total : nil
    }
    private var totalText: String {
        guard let value = windowValue else { return "Unavailable" }
        let partial = series.authoritativeTotals.map { metric.isPartial($0) } ?? false
        return (partial ? "≥" : "") + Self.compact(value)
    }
    private var totalDescription: String {
        guard let totals = series.authoritativeTotals else { return "No normalized token total is available for this snapshot." }
        switch metric {
        case .total:
            return (totals.tokensKnown.map { $0.formatted() + " known tokens. " } ?? "Total tokens unavailable. ")
                + "Totals reported for \(totals.tokenReceipts) of \(totals.usageRecords) usage readings. Missing readings are not zero."
        case .output:
            return (totals.outputKnown.map { $0.formatted() + " known output tokens. " } ?? "Output unavailable. ")
                + "Output reported for \(totals.outputReceipts) of \(totals.usageRecords) usage readings."
        case .weighted:
            return totals.weightedEquivalent.map { $0.formatted(.number.precision(.fractionLength(0 ... 2))) + " adjusted units under \(totals.weightingVersion); not a price." }
                ?? "Adjusted comparison unavailable because the token breakdown is incomplete."
        }
    }
    private var chartDomain: ClosedRange<Date> {
        let start = series.windowFrom ?? series.points.first?.start ?? Date(timeIntervalSince1970: 0)
        let end = series.windowTo ?? series.points.last.map { $0.end ?? $0.start.addingTimeInterval(bucket == .hour ? 3_600 : 86_400) } ?? start.addingTimeInterval(1)
        return start ... max(end, start.addingTimeInterval(0.001))
    }
    private var reportingCalendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = ActivityAnalytics.reportingTimeZone; return value
    }
    private var interruptions: [ActivityConnectionHistory.Interval] {
        snapshot.connectionHistory?.interruptions(from: chartDomain.lowerBound, to: chartDomain.upperBound) ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("Measurement", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityIdentifier("hub.tokens.measurement")
            if rows.isEmpty { emptyState } else { chart }
            footer
        }
        .bridgeCard()
        .environment(\.calendar, reportingCalendar)
        .environment(\.timeZone, ActivityAnalytics.reportingTimeZone)
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            guard let response = Self.acceptanceResponse(name: AcceptanceProbe.requestName(note), value: AcceptanceProbe.requestValue(note),
                    scope: AcceptanceProbe.requestScope(note), active: AcceptanceProbe.isActive, bucket: bucket, metric: metric) else { return }
            bucket = response.bucket
            metric = response.metric
            var state = response.state
            let milliseconds = snapshot.generatedAt.timeIntervalSince1970 * 1_000
            if milliseconds.isFinite, milliseconds >= Double(Int64.min), milliseconds < Double(Int64.max) {
                state["asOfMS"] = String(Int64(milliseconds.rounded()))
            }
            AcceptanceProbe.record(note, scope: "panel-chart", state: state, supported: response.supported)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SectionTitle(text: "Token activity")
            Spacer()
            Picker("Time window", selection: $bucket) {
                Text("24h").tag(TokenBucketSize.hour)
                Text("14d").tag(TokenBucketSize.day)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 88)
            .accessibilityIdentifier("hub.tokens.window")
            Button(action: onRefresh) {
                if isBusy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(BridgeIconButtonStyle()).disabled(isBusy || !isReady)
            .help("Refresh saved activity for all reports")
            .accessibilityLabel("Refresh token activity")
            .accessibilityIdentifier("hub.tokens.refresh")
        }
    }

    private var chart: some View {
        Chart {
            ForEach(interruptions) { interval in
                RectangleMark(xStart: .value("Network interruption start", interval.start), xEnd: .value("Network interruption end", interval.end),
                              yStart: .value("Plot baseline", 0), yEnd: .value("Plot extent", max(rows.map(\.upper).max() ?? 1, 1)))
                    .foregroundStyle(BridgeTheme.warning.opacity(0.10))
                    .accessibilityLabel("Network interruption observed on this Mac; not proof of a provider outage")
            }
            ForEach(rows) { row in
                RectangleMark(xStart: .value("Start", row.barStart), xEnd: .value("End", row.barEnd),
                          yStart: .value(metric.rawValue, row.lower), yEnd: .value(metric.rawValue, row.upper))
                .foregroundStyle(by: .value("Provider", row.label))
                .cornerRadius(2)
                .accessibilityLabel(Text(row.label))
                .accessibilityValue(Text((row.partial ? "At least " : "") + Self.compact(row.value) + " " + metric.rawValue.lowercased()))
            }
        }
        .chartXScale(domain: chartDomain)
        .chartForegroundStyleScale(domain: ["Claude", "Codex", "Grok", "Other"], range: [BridgeTheme.claude, BridgeTheme.codex, BridgeTheme.grok, BridgeTheme.textTertiary])
        .chartLegend(position: .bottom, spacing: 6)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel { if let count = value.as(Double.self) { Text(Self.compact(count)) } }
            }
        }
        .chartXAxis {
            if bucket == .hour {
                AxisMarks(values: .stride(by: .hour, count: 6)) { AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) }
            } else {
                AxisMarks(values: .stride(by: .day, count: 3)) { AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day()) }
            }
        }
        .frame(height: 132)
        .accessibilityLabel("\(metric.rawValue) from the shared saved-activity snapshot")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(totalText).font(.callout.weight(.semibold).monospacedDigit())
                    .help(totalDescription).accessibilityLabel(totalDescription)
                Text(bucket == .hour ? "in the last 24 hours" : "in 14 calendar days")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            if (series.unallocated?.usageRecords ?? 0) > 0 {
                Text("Some readings are included in the total but cannot be placed on the chart.")
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary)
            }
            if snapshot.historyIsPartial == true {
                Label("Partial saved history", systemImage: "clock.badge.questionmark")
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.warning)
                    .help("Collection coverage is partial. Measurement completeness is shown separately; this badge does not change a reported token total.")
            }
            if !interruptions.isEmpty {
                Label("Network interruption recorded", systemImage: "wifi.slash")
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.warning)
                    .help(ActivityConnectionHistory.explanation)
            }
            DisclosureGroup("About these numbers") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(metric.explanation)
                    Text(ActivityConnectionHistory.explanation)
                    Text("Same saved receipts as Models and metrics exports. This is local activity, not subscription capacity or a bill. Blank buckets mean no timed measurement, not necessarily no work.")
                    if let status = snapshot.statusMessage { Text(status).foregroundStyle(BridgeTheme.warning) }
                    if snapshot.hourlyScope != nil {
                        Text("Snapshot: \(Self.snapshotTime(snapshot.generatedAt)) · \(Self.reportingZoneName)")
                    }
                    if metric == .weighted { Text("Comparison policy: fresh-input-equivalent/1") }
                }
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary).padding(.top, 5)
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            .accessibilityIdentifier("hub.tokens.about")
        }
    }

    private var emptyState: some View {
        HStack(spacing: 7) {
            Image(systemName: "chart.bar").foregroundStyle(BridgeTheme.textTertiary)
            Text(emptyMessage)
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
    }
    private var emptyMessage: String {
        if snapshot.hourlyScope == nil { return snapshot.statusMessage ?? "Refresh activity to read your saved history." }
        if windowValue != nil { return "A known total is available, but no timed bars can be drawn." }
        return metric == .weighted ? "A complete token breakdown is needed for this comparison." : "No measured token readings in this window."
    }

    static func compact(_ value: Int) -> String { compact(Double(value)) }
    static func compact(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1)))
    }
    /// The zone the hours are bucketed in: this Mac's own, never a fixed city.
    private static var reportingZoneName: String {
        let zone = ActivityAnalytics.reportingTimeZone
        return zone.localizedName(for: .standard, locale: .current) ?? zone.identifier
    }
    private static func snapshotTime(_ value: Date) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = ActivityAnalytics.reportingTimeZone; formatter.locale = .current; formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: value)
    }
}
