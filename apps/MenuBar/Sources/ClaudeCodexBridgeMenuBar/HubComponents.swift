import AppKit
import BridgeCore
import SwiftUI

private struct ActivityContentVisibilityKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var activityContentVisible: Bool {
        get { self[ActivityContentVisibilityKey.self] }
        set { self[ActivityContentVisibilityKey.self] = newValue }
    }
}

// MARK: - Brand

/// The Playbasis "P" mark, packaged with the app.
enum BrandArtwork {
    static var mark: NSImage? {
        let name = NSImage.Name("Hub.Brand.Mark")
        if let cached = NSImage(named: name) { return cached }
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Brand/playbasis-mark.png")
        let url: URL?
        if let packaged, FileManager.default.fileExists(atPath: packaged.path) { url = packaged }
        else if Bundle.main.bundleURL.pathExtension == "app" { url = nil }
        else { url = Bundle.module.url(forResource: "playbasis-mark", withExtension: "png", subdirectory: "Brand") }
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        image.setName(name)
        return image
    }
}

struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image = BrandArtwork.mark {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Circle().fill(LinearGradient(colors: [BridgeTheme.brandDeep, BridgeTheme.brand], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Text("P").font(.system(size: size * 0.5, weight: .bold, design: .rounded)).foregroundStyle(.white))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Highlights

/// One observation as a tinted card: icon, headline figure, sentence, detail.
struct HighlightCard: View {
    var highlight: ActivityHighlight
    var compact = false
    var action: (() -> Void)? = nil
    @State private var hovering = false

    private var tint: Color {
        if let provider = highlight.provider, highlight.tone == .neutral || highlight.tone == .positive {
            return BridgeTheme.color(for: provider)
        }
        return BridgeTheme.tone(highlight.tone)
    }

    var body: some View {
        Group {
            if let action {
                Button(action: action) { card }.buttonStyle(.plain)
            } else { card }
        }
        .onHover { hovering = $0 && action != nil }
        .help(highlight.note ?? highlight.detail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(highlight.value), \(highlight.title). \(highlight.detail)")
        .accessibilityHint(highlight.note ?? "")
    }

    private var valueColor: Color { highlight.tone == .neutral && highlight.provider == nil ? BridgeTheme.textPrimary : tint }

    private var card: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        // Fills a fixed-height row so neighbouring cards share one height.
        .frame(maxWidth: .infinity, maxHeight: compact ? nil : .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous)
                .fill(tint.opacity(hovering ? 0.13 : (highlight.tone == .alert ? 0.10 : 0.05)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous)
                .strokeBorder(tint.opacity(highlight.tone == .alert ? 0.45 : (hovering ? 0.3 : 0.14)), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    /// Value first: the figure is the headline, the title says what it is.
    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                symbolTile(size: 24, glyph: 11)
                Spacer(minLength: 4)
                if action != nil {
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(hovering ? tint : BridgeTheme.textTertiary)
                }
            }
            Text(highlight.value)
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.top, 10)
            Text(highlight.title).font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Text(highlight.detail).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
    }

    private var compactBody: some View {
        HStack(alignment: .top, spacing: 9) {
            symbolTile(size: 22, glyph: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(highlight.title).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(highlight.detail).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(highlight.value)
                .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1).fixedSize()
        }
        .padding(10)
    }

    private func symbolTile(size: CGFloat, glyph: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.opacity(0.16))
            Image(systemName: highlight.symbol).font(.system(size: glyph, weight: .semibold)).foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "What stands out": a headed row of highlight cards. The row shares the
/// full width when the cards fit, so four highlights never leave an empty
/// fifth slot, and wraps into a grid when the window is narrow.
struct HighlightsSection: View {
    var periodPhrase: String
    var info: String
    var items: [ActivityHighlight]
    var minimumWidth: CGFloat = 200
    var action: (ActivityHighlight) -> (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)).foregroundStyle(BridgeTheme.brand)
                Text("What stands out").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                Text("· \(periodPhrase)").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textTertiary)
                InfoButton(title: "What stands out", text: info)
            }
            // All in one row, else balanced rows (four become 2 × 2, never
            // 3 + 1), else one column.
            ViewThatFits(in: .horizontal) {
                rows(columns: items.count)
                if items.count > 2 { rows(columns: (items.count + 1) / 2) }
                rows(columns: 1)
            }
        }
    }

    private func rows(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(stride(from: 0, to: items.count, by: max(1, columns))), id: \.self) { start in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(items[start ..< min(items.count, start + columns)]) { item in
                        // One or two highlights keep a card's width rather
                        // than stretching into banners.
                        HighlightCard(highlight: item, action: action(item))
                            .frame(minWidth: minimumWidth, idealWidth: minimumWidth, maxWidth: items.count >= 3 ? .infinity : minimumWidth * 1.7,
                                   maxHeight: .infinity, alignment: .top)
                    }
                    if items.count < 3 { Spacer(minLength: 0) }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Depth on demand

/// A quiet ⓘ that explains a figure in a popover. Methodology lives here, not
/// in captions, so the page stays readable until someone asks.
struct InfoButton: View {
    var title: String
    var text: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "info.circle").font(.system(size: 11, weight: .regular)).foregroundStyle(BridgeTheme.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("About \(title)")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(BridgeFont.heading)
                Text(text).font(BridgeFont.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(width: 300, alignment: .leading)
        }
    }
}

/// Change against the previous period as a small arrow chip.
struct DeltaChip: View {
    var delta: Double?
    var label: String

    var body: some View {
        if let delta, let text = ActivityFormat.delta(delta) {
            let color = delta > 0.005 ? BridgeTheme.brand : delta < -0.005 ? BridgeTheme.textSecondary : BridgeTheme.textTertiary
            HStack(spacing: 2) {
                Image(systemName: delta > 0.005 ? "arrow.up.right" : delta < -0.005 ? "arrow.down.right" : "equal")
                    .font(.system(size: 7, weight: .heavy))
                Text(text)
            }
            .font(BridgeFont.micro.monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.13), in: Capsule())
            .help("\(text) \(label)")
            .accessibilityLabel("\(text) \(label)")
        }
    }
}

/// Section heading for report cards: icon, title, optional ⓘ and trailing view.
struct CardHeader<Trailing: View>: View {
    var title: String
    var icon: String
    var subtitle: String? = nil
    var info: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                    if let info { InfoButton(title: title, text: info) }
                }
                if let subtitle { Text(subtitle).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary) }
            }
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(title: String, icon: String, subtitle: String? = nil, info: String? = nil) {
        self.init(title: title, icon: icon, subtitle: subtitle, info: info) { EmptyView() }
    }
}

// MARK: - Toolbar controls

struct HubSearchField: View {
    var prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(BridgeTheme.textTertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(BridgeFont.secondary)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(BridgeTheme.textTertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8).frame(height: 26)
        .bridgeWell(cornerRadius: 7)
    }
}

/// Provider scope as logo toggles. "All" is text; providers are their marks.
struct ProviderScopeControl: View {
    @Binding var selection: String
    var providers: [AgentName]

    var body: some View {
        HStack(spacing: 2) {
            option("all", label: AnyView(Text("All").font(BridgeFont.secondaryMedium)), help: "All providers")
            ForEach(providers, id: \.self) { provider in
                option(provider.rawValue, label: AnyView(AgentAvatar(name: provider.rawValue.capitalized, size: 14).frame(width: 20, height: 20)),
                       help: "Only \(provider.rawValue.capitalized)")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.18)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(BridgeTheme.wellBorder, lineWidth: 1))
    }

    private func option(_ value: String, label: AnyView, help: String) -> some View {
        Button { selection = value } label: {
            label
                .foregroundStyle(selection == value ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
                .padding(.horizontal, value == "all" ? 8 : 2).frame(height: 22)
                .background {
                    if selection == value { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.11)) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(selection == value || selection == "all" ? 1 : 0.55)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selection == value ? [.isSelected] : [])
    }
}

// MARK: - Weekday × hour

/// When requests happen across a week, Monday first, one cell per hour.
struct WeekHourGrid: View {
    var counts: [[Int]]
    var tint: Color = BridgeTheme.codex
    private var peak: Int { counts.flatMap { $0 }.max() ?? 0 }
    private static let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { proxy in
                let label: CGFloat = 30
                let gap: CGFloat = 2
                let cell = max(4, (proxy.size.width - label - 23 * gap) / 24)
                VStack(alignment: .leading, spacing: gap) {
                    ForEach(0 ..< 7, id: \.self) { day in
                        HStack(spacing: gap) {
                            Text(Self.days[day]).font(.system(size: 9, weight: .medium)).foregroundStyle(BridgeTheme.textTertiary)
                                .frame(width: label, alignment: .leading)
                            ForEach(0 ..< 24, id: \.self) { hour in
                                let value = counts.indices.contains(day) && counts[day].indices.contains(hour) ? counts[day][hour] : 0
                                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                    .fill(fill(value))
                                    .frame(width: cell, height: 14)
                                    .help(value == 0 ? "\(Self.days[day]) \(hourLabel(hour)): no requests" : "\(Self.days[day]) \(hourLabel(hour))–\(hourLabel(hour + 1)): \(value) \(value == 1 ? "request" : "requests")")
                            }
                        }
                    }
                }
            }
            .frame(height: 7 * 14 + 6 * 2)
            HStack(spacing: 0) {
                Spacer().frame(width: 30)
                ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { hour in
                    Text(hourLabel(hour)).font(.system(size: 9)).foregroundStyle(BridgeTheme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Requests by weekday and hour")
        .accessibilityValue(peak > 0 ? "Busiest hour has \(peak) requests" : "No requests")
    }

    private func fill(_ value: Int) -> Color {
        guard value > 0, peak > 0 else { return Color.white.opacity(0.045) }
        return tint.opacity(0.2 + 0.8 * sqrt(Double(value) / Double(peak)))
    }

    private func hourLabel(_ hour: Int) -> String { Self.hourLabels[hour % 24] }

    /// The grid draws 168 cells, each with hour labels; format the 24 once.
    private static let hourLabels: [String] = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("j")
        let calendar = Calendar(identifier: .gregorian)
        return (0 ..< 24).map { hour in
            var components = DateComponents(); components.hour = hour
            let date = calendar.date(from: components) ?? Date()
            return formatter.string(from: date).replacingOccurrences(of: " ", with: "").lowercased()
        }
    }()
}

// MARK: - Year calendar

/// A year of provider-reported daily usage, one square per day, like a
/// contribution calendar. Quartile shading keeps one huge day from flattening
/// the rest; hover shows the exact figure.
struct YearHeatmap: View {
    var days: [ActivityAccountDay]
    var end: Date
    var tint: Color = BridgeTheme.codex

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // Account dates are provider labels, not a known source time zone.
        // UTC is a stable layout coordinate, never a timezone attribution.
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }

    private var values: [Date: ActivityAnalytics.AccountDay] {
        Dictionary(uniqueKeysWithValues: ActivityAnalytics.accountDays(days).map { ($0.day, $0) })
    }

    var body: some View {
        let lastWeek = calendar.dateInterval(of: .weekOfYear, for: end)?.start ?? end
        let firstWeek = calendar.date(byAdding: .weekOfYear, value: -52, to: lastWeek) ?? lastWeek
        let today = calendar.startOfDay(for: end)
        let values = self.values.filter { $0.key >= firstWeek && $0.key <= today }
        let thresholds = quartiles(values.values.compactMap(\.tokens).filter { $0 > 0 })
        VStack(alignment: .leading, spacing: 5) {
            // Columns share the width; squares keep a 1:1 ratio, so the
            // calendar fills any card width without a measured height.
            HStack(alignment: .bottom, spacing: Self.gap) {
                ForEach(0 ..< 53, id: \.self) { week in
                    Text(monthLabel(week: week, firstWeek: firstWeek))
                        .font(.system(size: 9)).foregroundStyle(BridgeTheme.textTertiary)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 11)
            HStack(alignment: .top, spacing: Self.gap) {
                ForEach(0 ..< 53, id: \.self) { week in
                    weekColumn(week, firstWeek: firstWeek, today: today, values: values, thresholds: thresholds)
                }
            }
            legend
        }
        .frame(maxWidth: 1_000, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily Codex account usage over the past year")
        .accessibilityValue("\(values.values.filter { $0.tokens != nil }.count) days reported. Outlined cells have no reported value; filled grey cells are reported zero.")
    }

    private static let gap: CGFloat = 3

    private func weekColumn(_ week: Int, firstWeek: Date, today: Date, values: [Date: ActivityAnalytics.AccountDay], thresholds: [Int]) -> some View {
        VStack(spacing: Self.gap) {
            ForEach(0 ..< 7, id: \.self) { weekday in
                dayCell(calendar.date(byAdding: .day, value: week * 7 + weekday, to: firstWeek) ?? firstWeek,
                        today: today, values: values, thresholds: thresholds)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func dayCell(_ date: Date, today: Date, values: [Date: ActivityAnalytics.AccountDay], thresholds: [Int]) -> some View {
        let reading = values[date]
        let value = reading?.tokens
        let future = date > today
        let isToday = calendar.isDate(date, inSameDayAs: today)
        let unavailable = reading?.conflicting == true ? "conflicting readings" : "not reported"
        let label = future ? "" : "\(dateLabel(date)): \(value.map { $0.formatted() + " tokens" } ?? unavailable)"
        let outline = isToday ? BridgeTheme.textPrimary : reading?.conflicting == true ? BridgeTheme.warning : BridgeTheme.textSecondary
        return RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(future ? Color.clear : value.map { fill($0, thresholds) } ?? Color.clear)
            .overlay {
                if !future && (value == nil || isToday) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(outline.opacity(isToday ? 0.9 : 0.35), style: StrokeStyle(lineWidth: 1, dash: value == nil ? [1, 1] : []))
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .help(label)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(BridgeTheme.textSecondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [1, 1]))
                .frame(width: 9, height: 9)
            Text("Not reported").font(.system(size: 9)).foregroundStyle(BridgeTheme.textTertiary)
            Spacer()
            Text("0").font(.system(size: 9)).foregroundStyle(BridgeTheme.textTertiary)
            ForEach(0 ..< 5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(level == 0 ? Color.white.opacity(0.05) : tint.opacity([0, 0.3, 0.5, 0.75, 1][level]))
                    .frame(width: 9, height: 9)
            }
            Text("More").font(.system(size: 9)).foregroundStyle(BridgeTheme.textTertiary)
        }
    }

    private func quartiles(_ values: [Int]) -> [Int] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { sorted[min(sorted.count - 1, Int(Double(sorted.count) * $0))] }
    }

    private func fill(_ value: Int, _ thresholds: [Int]) -> Color {
        guard value > 0 else { return Color.white.opacity(0.05) }
        let level = thresholds.filter { value > $0 }.count
        return tint.opacity([0.3, 0.5, 0.75, 1][min(3, level)])
    }

    private func monthLabel(week: Int, firstWeek: Date) -> String {
        let weekStart = calendar.date(byAdding: .weekOfYear, value: week, to: firstWeek) ?? firstWeek
        let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: weekStart) ?? weekStart
        guard week == 0 || calendar.component(.month, from: weekStart) != calendar.component(.month, from: previous) else { return "" }
        if week == 0 && calendar.component(.day, from: weekStart) > 21 { return "" }
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone; formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        return formatter.string(from: weekStart)
    }

    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Token composition

/// A 100% bar showing what tokens were: new input, re-read context, context
/// saved for reuse, and what the model wrote.
struct TokenCompositionBar: View {
    var composition: ActivityAccounting.Breakdown
    var showLegend = true
    /// Split only what was not re-read, when re-reading dominates the whole.
    var omitReread = false

    struct Part: Identifiable { var id: String { name }; var name: String; var value: Int; var color: Color; var help: String }

    var parts: [Part] {
        [
            Part(name: "New input", value: composition.freshInput, color: BridgeTheme.gemini, help: "Prompts, files and tool results read for the first time"),
            Part(name: "Re-read context", value: composition.rereadContext, color: BridgeTheme.codex.opacity(0.55), help: "Conversation and files the model had already seen, served from cache"),
            Part(name: "Saved for reuse", value: composition.cacheWrites, color: BridgeTheme.warning.opacity(0.8), help: "Context written to the cache so later steps can re-read it cheaply"),
            Part(name: "Written", value: composition.output, color: BridgeTheme.claude, help: "Text, code and reasoning the model produced"),
        ].filter { $0.value > 0 && !(omitReread && $0.name == "Re-read context") }
    }

    var body: some View {
        if let measured = composition.total {
            content(total: max(1, omitReread ? parts.reduce(0) { $0 + $1.value } : measured))
        } else {
            Text("Token breakdown unavailable").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
        }
    }

    private func content(total: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { proxy in
                let widths = ActivityModelAccounting.segmentWidths(counts: parts.map(\.value), width: Double(proxy.size.width))
                HStack(spacing: 0) {
                    ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                        Rectangle().fill(part.color)
                            .frame(width: CGFloat(widths[index]))
                            .overlay(alignment: .trailing) { Rectangle().fill(BridgeTheme.ink).frame(width: min(1, CGFloat(widths[index]))) }
                            .help("\(part.name): \(ActivityFormat.compact(part.value)) · \(part.help)")
                    }
                }
            }
            .frame(height: 8).clipShape(Capsule())
            if showLegend {
                HStack(spacing: 12) {
                    ForEach(parts) { part in
                        HStack(spacing: 4) {
                            Circle().fill(part.color).frame(width: 6, height: 6)
                            Text(part.name).foregroundStyle(BridgeTheme.textSecondary)
                            Text(share(part.value, total)).foregroundStyle(BridgeTheme.textTertiary).monospacedDigit()
                        }
                        .help(part.help)
                    }
                }
                .font(BridgeFont.micro).lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Token composition")
        .accessibilityValue(parts.isEmpty ? "Reported zero tokens" : parts.map { "\($0.name) \(share($0.value, total))" }.joined(separator: ", "))
    }

    private func share(_ value: Int, _ total: Int) -> String {
        let fraction = Double(value) / Double(total)
        if fraction > 0 && fraction < 0.01 { return "<1%" }
        if fraction < 1 && fraction > 0.99 { return ">99%" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}

// MARK: - Empty states

struct HubEmptyState: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(BridgeTheme.brand.opacity(0.12)).frame(width: 52, height: 52)
                Image(systemName: icon).font(.system(size: 21, weight: .medium)).foregroundStyle(BridgeTheme.brand)
            }
            Text(title).font(BridgeFont.title).foregroundStyle(BridgeTheme.textPrimary)
            Text(message).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380).fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(BridgeSecondaryButtonStyle(compact: true)).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 36)
    }
}

/// Icon and title with a tight gap, for dense metadata lines.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 9.5, weight: .semibold)).imageScale(.small)
            configuration.title
        }
    }
}

/// A tinted notice: coloured icon and accent, readable white title, grey
/// detail. Colour signals urgency; the text stays high-contrast.
struct CalloutBanner: View {
    var tone: ActivityHighlight.Tone
    var title: String
    var detail: String? = nil
    var icon: String = "exclamationmark.triangle.fill"
    var note: String? = nil
    var compact = false

    var body: some View {
        let color = BridgeTheme.tone(tone)
        HStack(alignment: .top, spacing: compact ? 7 : 9) {
            Image(systemName: icon).font(.system(size: compact ? 10 : 12, weight: .semibold)).foregroundStyle(color)
                .padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(compact ? BridgeFont.captionMedium : BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 7 : 9).padding(.leading, compact ? 9 : 11).padding(.trailing, 9)
        .background(color.opacity(tone == .alert ? 0.16 : 0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangleCompat(color: color)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(note ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityHint(note ?? "")
    }
}

/// The 3 pt accent on a callout's leading edge (macOS 13 has no
/// UnevenRoundedRectangle, so the parent's clip shape rounds it).
private struct UnevenRoundedRectangleCompat: View {
    var color: Color
    var body: some View { Rectangle().fill(color).frame(width: 3) }
}

// MARK: - Metric strip

/// A compact trend in one Canvas pass. A missing measurement is a faint dot,
/// an empty coordinate is a quiet baseline, and measured zero is a tinted
/// hairline. These three states never silently collapse into the same zero.
struct MiniBars: View {
    var values: [Double?]
    var tint: Color
    var emphasis: Int? = nil
    var emptyIndices: Set<Int> = []
    var height: CGFloat = 26

    var body: some View {
        Canvas { context, size in
            guard !values.isEmpty, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
            let peak = values.compactMap { $0 }.filter { $0.isFinite && $0 >= 0 }.max() ?? 0
            let geometry = MiniBarsPresentation.geometry(width: size.width, count: values.count)
            let width = geometry.barWidth, gap = geometry.gap
            let strong = emphasis ?? values.count - 1
            for (index, sample) in MiniBarsPresentation.samples(values, emptyIndices: emptyIndices).enumerated() {
                let x = CGFloat(index) * (width + gap)
                if sample == .noRecords {
                    let h = min(0.5, size.height)
                    let baseline = CGRect(x: x, y: size.height - h, width: width, height: h)
                    context.fill(Path(baseline), with: .color(BridgeTheme.textTertiary.opacity(0.3)))
                    continue
                }
                guard case let .measured(value) = sample else {
                    let diameter = min(2, width, size.height)
                    let dot = CGRect(x: x + (width - diameter) / 2, y: size.height - diameter, width: diameter, height: diameter)
                    context.fill(Path(ellipseIn: dot), with: .color(Color.white.opacity(0.18)))
                    continue
                }
                let barHeight = peak > 0 && value > 0 ? max(min(2, size.height), size.height * CGFloat(value / peak)) : min(1, size.height)
                let rect = CGRect(x: x, y: size.height - barHeight, width: width, height: barHeight)
                context.fill(Path(roundedRect: rect, cornerRadius: min(1.5, width / 2)),
                             with: .color(tint.opacity(index == strong ? 0.95 : (value > 0 ? 0.42 : 0.25))))
            }
        }
        .frame(height: height.isFinite ? max(0, height) : 0)
        .accessibilityHidden(true)
    }
}

struct MetricItem: Identifiable {
    var title: String
    var icon: String
    var value: String
    var delta: Double? = nil
    var deltaLabel: String = ""
    var footnote: String? = nil
    var info: String? = nil
    var series: [Double?] = []
    var emptyIndices: Set<Int> = []
    var emphasis: Int? = nil
    var id: String { title }
}

/// Headline metrics in one card: equal cells divided by hairlines, each with
/// a label, a figure, a bar trend and one line of context. Six across at
/// desktop widths, then three, two or one column as space gets narrower.
struct MetricStrip: View {
    var items: [MetricItem]
    var tint: Color = BridgeTheme.brand

    var body: some View {
        ViewThatFits(in: .horizontal) {
            rows(columns: 6)
            rows(columns: 3)
            rows(columns: 2)
            rows(columns: 1)
        }
        .background(BridgeTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(BridgeTheme.surfaceBorder, lineWidth: 1))
    }

    private func rows(columns: Int) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(stride(from: 0, to: items.count, by: max(1, columns))), id: \.self) { start in
                if start > 0 { Rectangle().fill(BridgeTheme.separator).frame(height: 1) }
                row(Array(items[start ..< min(items.count, start + columns)]))
            }
        }
    }

    private func row(_ items: [MetricItem]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Rectangle().fill(BridgeTheme.separator).frame(width: 1).padding(.vertical, 14) }
                cell(item)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ item: MetricItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: item.icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary)
                    .frame(width: 12)
                Text(item.title).font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                if let info = item.info { InfoButton(title: item.title, text: info) }
                Spacer(minLength: 4)
                DeltaChip(delta: item.delta, label: item.deltaLabel)
            }
            Text(item.value)
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(BridgeTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.top, 9)
            // A strip without any trends drops the row instead of leaving a
            // blank band between each figure and its footnote.
            if items.contains(where: { !$0.series.isEmpty }) {
                Group {
                    if item.series.isEmpty { Color.clear } else { MiniBars(values: item.series, tint: tint, emphasis: item.emphasis, emptyIndices: item.emptyIndices, height: 24) }
                }
                .frame(height: 24).padding(.top, 10)
            }
            Text(item.footnote ?? " ").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                .lineLimit(1).truncationMode(.tail)
                .padding(.top, 8)
                .help(item.footnote ?? "")
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(minWidth: MetricStripLayout.minimumCellWidth, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(item.value)\(item.footnote.map { ", \($0)" } ?? ""). \(MiniBarsPresentation.accessibilitySummary(item.series, emptyIndices: item.emptyIndices))")
    }
}

// MARK: - Loading

/// Page-shaped placeholders shown until the first activity snapshot arrives,
/// so the layout doesn't jump and nothing claims "no sessions" prematurely.
/// Tiles flip in one after another, then a sweep cascades down the page
/// (`HydrationLoading.swift`).
struct ActivityLoadingView: View {
    var page: BridgePage
    var message: String
    var isReading = true

    var body: some View {
        HydrationClock(identity: page.id, enabled: isReading) { t in
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 8) {
                    HydrationGlyph(t: t)
                    Text(message).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.hydrationLabel)
                }
                .accessibilityElement(children: .combine)
                tiles(t)
            }
        }
        .accessibilityIdentifier("bridge.loading")
        .acceptanceProbe("loading")
        .allowsHitTesting(false)
    }

    @ViewBuilder private func tiles(_ t: Double?) -> some View {
        switch page {
        case .overview:
            HStack(spacing: 10) {
                ForEach(0 ..< 4, id: \.self) { HydrationTile(style: .card, order: $0, t: t, height: 138) }
            }
            HydrationTile(style: .banner, order: 4, t: t, height: 118, radius: 12)
            HStack(spacing: 12) {
                HydrationTile(style: .card, order: 5, t: t, height: 260)
                HydrationTile(style: .card, order: 6, t: t, height: 260)
            }
        case .team, .projects:
            HydrationTile(style: .banner, order: 0, t: t, height: 64, radius: 12)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
                ForEach(0 ..< 6, id: \.self) { HydrationTile(style: .card, order: 1 + $0, t: t, height: 190, radius: 12) }
            }
        default:
            HydrationTile(style: .banner, order: 0, t: t, height: 64, radius: 12)
            ForEach(0 ..< 7, id: \.self) { HydrationTile(style: .row, order: 1 + $0, t: t, height: 52, radius: 9) }
        }
    }
}

/// Plain row button with a subtle hover and press highlight, for tables.
struct HoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .background(Color.white.opacity(configuration.isPressed ? 0.07 : (hovering ? 0.04 : 0)))
                .onHover { hovering = $0 }
        }
    }
}

/// Applies a ⌘ keyboard shortcut only when there is one.
struct OptionalShortcut: ViewModifier {
    var key: KeyEquivalent?
    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key, modifiers: .command) } else { content }
    }
}

extension String {
    /// The string, or `fallback` when it is empty.
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
