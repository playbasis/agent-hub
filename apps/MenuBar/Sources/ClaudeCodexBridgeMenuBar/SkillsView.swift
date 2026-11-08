import AppKit
import BridgeCore
import SwiftUI

/// Reads the installed-skill catalog while the Skills page is open. The
/// reader is an actor with its own cache, so revisiting the page is instant.
@MainActor final class SkillCatalogModel: ObservableObject {
    /// One per app, so leaving and reopening the page keeps the catalog.
    static let shared = SkillCatalogModel()
    @Published private(set) var catalog: SkillCatalog?
    @Published private(set) var isReading = false

    func refresh(projects: [String]) async {
        isReading = true
        let value = await SkillCatalogReader.shared.catalog(projects: projects)
        if catalog?.revision != value.revision || catalog?.notes != value.notes { catalog = value }
        isReading = false
    }
}

/// The Skills page: which skills each agent can load, which ones they
/// actually load, where, at what context cost, and what needs a look.
struct SkillsView: View {
    var sessions: [ActivitySession]
    var overview: ActivityOverview
    var revision: UInt64
    var from: Date?
    var to: Date
    var hourly: Bool
    var periodPhrase: String
    var provider: String
    var project: String
    var query: String
    var catalogProjects: [String]
    var projectLabels: [String: String]
    @Binding var selection: String?
    var showSession: (String) -> Void

    @ObservedObject private var catalogModel = SkillCatalogModel.shared
    @State private var report: SkillReport.Result?
    /// The last report built, shown at once when the page is reopened with the
    /// same filters while a newer snapshot's report is built.
    @MainActor private static var lastReport: (key: ReportKey, result: SkillReport.Result)?
    @State private var filter: SkillFilter = .all
    @State private var sort: SkillSort = .loads
    @State private var width: CGFloat = 0
    @FocusState private var listFocused: Bool
    @Environment(\.activityContentVisible) private var contentVisible

    private static let sideBySideWidth: CGFloat = 960
    private static let listHeight: CGFloat = 612

    private struct ReportKey: Equatable {
        var revision: UInt64
        var from: Date?
        var to: Date
        var provider: String
        var project: String
        var hourly: Bool
        var catalog: String

        func sameSelection(as other: ReportKey) -> Bool {
            provider == other.provider && project == other.project && hourly == other.hourly
        }
    }

    private var shownReport: SkillReport.Result? {
        report ?? Self.lastReport.flatMap { $0.key.sameSelection(as: key) ? $0.result : nil }
    }

    private var key: ReportKey {
        ReportKey(revision: revision, from: from, to: to, provider: provider, project: project, hourly: hourly,
                  catalog: catalogModel.catalog?.revision ?? "pending")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let report = shownReport {
                if report.rows.isEmpty {
                    emptyState
                } else {
                    summary(report)
                    if !report.insights.isEmpty { insights(report) }
                    library(report)
                }
            } else {
                ActivityLoadingView(page: .skills, message: "Reading your skills…")
            }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { width = $0 }
        })
        .task(id: key) { await rebuild(key) }
        .task(id: catalogProjects) {
            // Skill folders change rarely; check once a minute while visible.
            while !Task.isCancelled {
                if contentVisible { await catalogModel.refresh(projects: catalogProjects) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.skills")
    }

    private func rebuild(_ key: ReportKey) async {
        let input = SkillReport.Input(sessions: sessions, catalog: catalogModel.catalog ?? .empty, from: from, to: to,
                                      provider: provider, project: project, hourly: hourly)
        if let last = Self.lastReport, last.key == key { report = last.result; return }
        let result = await Task.detached(priority: .userInitiated) { SkillReport.build(input) }.value
        guard !Task.isCancelled else { return }
        report = result
        Self.lastReport = (key, result)
    }

    // MARK: Empty

    private var emptyState: some View {
        HubEmptyState(
            icon: "wand.and.stars",
            title: catalogModel.catalog == nil ? "Looking for skills…" : "No skills yet",
            message: "Skills are reusable instructions an agent loads when a task calls for them. Add a folder with a SKILL.md to ~/.claude/skills for Claude Code or ~/.codex/skills for Codex, and it shows up here with every time it's used.")
    }

    // MARK: Summary

    private func summary(_ report: SkillReport.Result) -> some View {
        let totals = report.totals
        let series = loadSeries(report)
        let distinct = distinctSeries(report)
        let split = [AgentName.claude, .codex].compactMap { agent -> String? in
            guard let count = totals.loadsByProvider[agent], count > 0 else { return nil }
            return "\(SkillReport.providerName(agent)) \(count.formatted())"
        }.joined(separator: " · ")
        let listing = [AgentName.claude, .codex].compactMap { agent -> String? in
            guard let value = totals.listingTokens[agent], value > 0 else { return nil }
            return "\(SkillReport.providerName(agent)) ≈\(SkillReport.tokens(value))"
        }.joined(separator: " · ")
        let average = totals.tokensLoaded.flatMap { totals.loads > 0 ? $0 / totals.loads : nil }
        let elsewhere = totals.used - totals.installedUsed
        let idle = totals.installed - totals.installedUsed
        return MetricStrip(items: [
            MetricItem(title: "Skills in use", icon: "wand.and.stars",
                       value: "\(totals.installedUsed) of \(totals.installed)",
                       footnote: [idle > 0 ? "\(idle) not loaded" : "All loaded", elsewhere > 0 ? "+\(elsewhere) from elsewhere" : nil].compactMap { $0 }.joined(separator: " · "),
                       info: "Installed skills with at least one recorded load in \(periodPhrase), out of the skills installed for the agents in view. Skills an agent loaded that aren't in a folder the Hub reads, such as built-in or organization skills, are counted separately as from elsewhere.",
                       series: distinct),
            MetricItem(title: "Skill loads", icon: "arrow.down.doc", value: totals.loads.formatted(),
                       footnote: split.isEmpty ? "No loads recorded" : split,
                       info: "Each time an agent pulled a skill's instructions into its context: Claude Code's Skill tool or a slash command, or Codex reading the skill's SKILL.md.",
                       series: series),
            MetricItem(title: "Sessions using skills", icon: "rectangle.stack", value: totals.sessionsWithSkill.formatted(),
                       footnote: "\(totals.turnsWithSkill.formatted()) \(totals.turnsWithSkill == 1 ? "turn" : "turns") loaded one",
                       info: report.coverage.joined(separator: "\n\n")),
            MetricItem(title: "Context loaded", icon: "text.alignleft",
                       value: totals.tokensLoaded.map { "≈" + SkillReport.tokens($0) } ?? "—",
                       footnote: average.map { "≈\(SkillReport.tokens($0)) tokens a load" } ?? "Tokens of skill text",
                       info: "Estimated tokens of skill instructions pulled into context, at about four characters a token. Claude Code records the size of each loaded skill; for Codex the SKILL.md's size on disk is used. Files a skill points to are not included."),
            MetricItem(title: "Always-on list", icon: "list.bullet.rectangle",
                       value: listing.isEmpty ? "—" : "≈" + SkillReport.tokens(totals.listingTokens.values.reduce(0, +)),
                       footnote: listing.isEmpty ? "Waiting for installed skills" : listing,
                       info: "Each agent lists every installed skill's name and description at the start of every session so it can decide what to load. This is that list's estimated size per new session, used or not. Project skills are left out because they're listed only inside their project."),
        ], tint: BridgeTheme.brand)
    }

    private func loadSeries(_ report: SkillReport.Result) -> [Double?] {
        guard !report.bucketStarts.isEmpty else { return [] }
        var totals = Array(repeating: 0, count: report.bucketStarts.count)
        for row in report.rows where row.buckets.count == totals.count {
            for index in totals.indices { totals[index] += row.buckets[index] }
        }
        return totals.map { Double($0) }
    }

    private func distinctSeries(_ report: SkillReport.Result) -> [Double?] {
        guard !report.bucketStarts.isEmpty else { return [] }
        var counts = Array(repeating: 0, count: report.bucketStarts.count)
        for row in report.rows where row.buckets.count == counts.count {
            for index in counts.indices where row.buckets[index] > 0 { counts[index] += 1 }
        }
        return counts.map { Double($0) }
    }

    // MARK: Insights

    private func insights(_ report: SkillReport.Result) -> some View {
        HighlightsSection(periodPhrase: periodPhrase,
                          info: "Picked from recorded skill loads and the skill folders on this Mac. Amber is worth a look, cyan is unusual and grey is context. Hover a card to see how it was measured; click it to open the skill.",
                          items: report.insights.map(\.highlight), minimumWidth: 210) { highlight in
            report.insights.first { $0.highlight.id == highlight.id }.map(action(for:))
        }
    }

    // MARK: Library

    private func library(_ report: SkillReport.Result) -> some View {
        let rows = visibleRows(report)
        let selected = report.rows.first { $0.id == selection } ?? (width >= Self.sideBySideWidth ? rows.first : nil)
        return Group {
            if width >= Self.sideBySideWidth {
                HStack(alignment: .top, spacing: 14) {
                    libraryCard(report, rows: rows, selectedID: selected?.id).frame(maxWidth: .infinity, alignment: .topLeading)
                    detail(selected, report: report).frame(width: min(420, max(360, width * 0.36)))
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    libraryCard(report, rows: rows, selectedID: selected?.id)
                    if selected != nil { detail(selected, report: report) }
                }
            }
        }
    }

    @ViewBuilder private func detail(_ row: SkillReport.Row?, report: SkillReport.Result) -> some View {
        if let row {
            SkillDetailPanel(row: row, events: report.events(for: row.id), bucketStarts: report.bucketStarts, hourly: report.hourly,
                             periodPhrase: periodPhrase, to: to, sessions: sessionIndex, projectLabels: projectLabels,
                             history: catalogModel.catalog?.history ?? [:], repositories: overview.repositories,
                             allLoads: report.events(for: row.id, limit: 5_000),
                             inspect: inspect, showSession: showSession,
                             close: width >= Self.sideBySideWidth ? nil : { selection = nil })
                .id(row.id)
                .transition(.opacity)
        }
    }

    private var sessionIndex: [String: ActivitySession] {
        Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in lhs.observedAt >= rhs.observedAt ? lhs : rhs })
    }

    private func libraryCard(_ report: SkillReport.Result, rows: [SkillReport.Row], selectedID: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { libraryTitle(report); Spacer(minLength: 10); filters(report); sortMenu }
                VStack(alignment: .leading, spacing: 8) {
                    libraryTitle(report)
                    HStack(spacing: 8) { filters(report); Spacer(minLength: 0); sortMenu }
                }
            }
            if rows.isEmpty {
                Text(query.isEmpty ? "No skills match this filter." : "No skills match “\(query)”.")
                    .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                // The list scrolls on its own so the detail beside it stays in
                // view; ↑ and ↓ move the selection when the list has focus.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(rows) { row in
                                SkillRowView(row: row, selected: row.id == selectedID, compact: width < 640,
                                             needsLook: Self.needsLook(row), select: { select(row.id) })
                                    .id(row.id)
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: min(CGFloat(rows.count) * 51 + 7, Self.listHeight))
                    .bridgeWell(cornerRadius: 10)
                    .focusable()
                    .focused($listFocused)
                    .onMoveCommand { direction in
                        guard let index = rows.firstIndex(where: { $0.id == selectedID }) ?? (rows.isEmpty ? nil : -1) else { return }
                        let next: Int
                        switch direction {
                        case .up: next = max(0, index - 1)
                        case .down: next = min(rows.count - 1, index + 1)
                        default: return
                        }
                        select(rows[next].id)
                        withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(rows[next].id) }
                    }
                }
            }
        }
        .bridgeCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.skills.library")
    }

    private func libraryTitle(_ report: SkillReport.Result) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "books.vertical").font(.system(size: 12, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary)
            Text("Skill library").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
            Text("\(report.totals.installed) installed").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            if catalogModel.isReading && catalogModel.catalog == nil { ProgressView().controlSize(.mini) }
            InfoButton(title: "Skill library", text: "Skills in the folders each agent reads: ~/.claude/skills and each project's .claude/skills for Claude Code; ~/.codex/skills, its built-in skills and each project's .codex/skills for Codex; plus skills from installed plugins. A skill with the same folder name for both agents is shown once with both copies.")
        }
        .fixedSize()
    }

    private func filters(_ report: SkillReport.Result) -> some View {
        HStack(spacing: 4) {
            ForEach(SkillFilter.allCases) { option in
                let count = report.rows.filter { option.matches($0) }.count
                let isOn = filter == option
                Button { filter = option } label: {
                    HStack(spacing: 4) {
                        if option == .attention, count > 0 { Circle().fill(BridgeTheme.warning).frame(width: 5, height: 5) }
                        Text(option.title)
                        if option != .all { Text("\(count)").monospacedDigit().foregroundStyle(isOn ? BridgeTheme.brand : BridgeTheme.textTertiary) }
                    }
                    .font(BridgeFont.captionMedium)
                    .foregroundStyle(isOn ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(isOn ? BridgeTheme.brand.opacity(0.14) : Color.white.opacity(0.04), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(option != .all && count == 0 && !isOn)
                .accessibilityAddTraits(isOn ? [.isSelected] : [])
                .help(option.help)
            }
        }
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sort) {
                ForEach(SkillSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 9, weight: .semibold))
                Text(sort.title)
            }
            .font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textSecondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Sort skills")
        .accessibilityLabel("Sort skills, \(sort.title)")
    }

    private func visibleRows(_ report: SkillReport.Result) -> [SkillReport.Row] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var rows = report.rows.filter { filter.matches($0) }
        if !needle.isEmpty {
            rows = rows.filter { row in
                row.name.localizedCaseInsensitiveContains(needle) || row.summary.localizedCaseInsensitiveContains(needle)
                    || row.copies.contains { ($0.owner ?? "").localizedCaseInsensitiveContains(needle) }
            }
        }
        switch sort {
        case .loads: return rows
        case .recent: return rows.sorted { ($0.lastUsed ?? .distantPast, $1.name) > ($1.lastUsed ?? .distantPast, $0.name) }
        case .size: return rows.sorted { ($0.tokensPerLoad ?? 0) == ($1.tokensPerLoad ?? 0) ? $0.name < $1.name : ($0.tokensPerLoad ?? 0) > ($1.tokensPerLoad ?? 0) }
        case .name: return rows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func action(for insight: SkillReport.Insight) -> () -> Void {
        if let key = insight.skillKey { return { select(key) } }
        return { filter = .unused; selection = nil }
    }

    static func needsLook(_ row: SkillReport.Row) -> Bool { row.needsLook }

    private func select(_ key: String) {
        withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.15)) { selection = key }
        // A click keeps ↑/↓ working without a trip through Tab.
        listFocused = true
    }

    private func inspect(_ event: SkillReport.Event) {
        Task { @MainActor in
            ActivityReportsController.shared.inspectTurn(overview: overview, sessionID: event.sessionID, turnID: event.turnID, snapshotRevision: revision)
        }
    }
}

// MARK: - Filters

enum SkillFilter: String, CaseIterable, Identifiable {
    case all, used, unused, attention
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .used: return "In use"
        case .unused: return "Not loaded"
        case .attention: return "Needs a look"
        }
    }
    var help: String {
        switch self {
        case .all: return "Every installed skill, plus skills an agent loaded from elsewhere"
        case .used: return "Skills with at least one recorded load in this period"
        case .unused: return "Installed skills with no recorded load in this period"
        case .attention: return "An agent works where the skill is used but can't load it, its copies differ, or it's re-read often"
        }
    }
    func matches(_ row: SkillReport.Row) -> Bool {
        switch self {
        case .all: return true
        case .used: return row.isUsed
        case .unused: return !row.isUsed
        case .attention: return SkillsView.needsLook(row)
        }
    }
}

enum SkillSort: String, CaseIterable, Identifiable {
    case loads, recent, size, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .loads: return "Most loaded"
        case .recent: return "Recently used"
        case .size: return "Largest"
        case .name: return "Name"
        }
    }
}

// MARK: - Row

/// One skill: identity on the left, its trend and recency on the right.
private struct SkillRowView: View {
    var row: SkillReport.Row
    var selected: Bool
    var compact: Bool
    var needsLook: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 11) {
                SkillMonogram(name: row.name, providers: row.installedFor.isEmpty ? row.usedBy : row.installedFor, size: 30, dimmed: !row.isUsed)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.name).font(BridgeFont.bodyMedium).foregroundStyle(row.isUsed ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
                            .lineLimit(1).truncationMode(.middle)
                        Tag(text: SkillPresentation.scopeLabel(row))
                        if needsLook {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(BridgeTheme.warning)
                                .help("Needs a look: open the skill to see why")
                        }
                    }
                    Text(row.summary.ifEmpty(row.copies.isEmpty ? "Loaded by an agent; not installed in a folder the Hub reads" : "No description"))
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                providerMarks
                if !compact {
                    MiniBars(values: row.buckets.map { Double($0) }, tint: BridgeTheme.brand, emptyIndices: [], height: 18)
                        .frame(width: 72)
                        .opacity(row.isUsed ? 1 : 0.35)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(row.loads > 0 ? row.loads.formatted() : "—")
                        .font(BridgeFont.numeral).foregroundStyle(row.isUsed ? BridgeTheme.textPrimary : BridgeTheme.textTertiary)
                    Text(row.lastUsed.map { ActivityFormat.relative($0) } ?? "not loaded")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                }
                .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, 10).frame(height: 50)
            .background(selected ? BridgeTheme.brand.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? BridgeTheme.brand.opacity(0.45) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(SkillPresentation.scopeLabel(row)), \(row.loads) loads\(row.lastUsed.map { ", last used \(ActivityFormat.relative($0))" } ?? ", not loaded")\(needsLook ? ", needs a look" : "")")
        .accessibilityHint("Show details")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
    }

    /// Agents that loaded it at full strength; installed but idle, faded;
    /// missing where it was needed, as an amber ring.
    private var providerMarks: some View {
        HStack(spacing: -3) {
            ForEach([AgentName.claude, .codex], id: \.self) { agent in
                let installed = row.installedFor.contains(agent)
                let used = (row.loadsByProvider[agent] ?? 0) > 0
                if installed || used {
                    AgentAvatar(name: agent.rawValue.capitalized, size: 13, dimmed: !used)
                        .help(used ? "\(SkillReport.providerName(agent)) loaded it \(row.loadsByProvider[agent] ?? 0)×"
                                   : "Installed for \(SkillReport.providerName(agent)), not loaded in this period")
                } else if let sessions = row.missingSessions[agent] {
                    Circle().strokeBorder(BridgeTheme.warning, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                        .frame(width: 13, height: 13).frame(width: 21, height: 21)
                        .help("\(SkillReport.providerName(agent)) had \(sessions) sessions where this skill was used, but can't load it")
                }
            }
        }
        .frame(minWidth: 30, alignment: .trailing)
    }
}

// MARK: - Detail

/// Everything about one skill: what it is, who loads it, where, what the
/// turns around it looked like, its context cost, and its installed copies.
private struct SkillDetailPanel: View {
    var row: SkillReport.Row
    var events: [SkillReport.Event]
    var bucketStarts: [Date]
    var hourly: Bool
    var periodPhrase: String
    var to: Date
    var sessions: [String: ActivitySession]
    var projectLabels: [String: String]
    var history: [String: ContextFileRecord]
    var repositories: [ActivityRepository]
    /// Every load in the period, for counting each version's use.
    var allLoads: [SkillReport.Event]
    var inspect: (SkillReport.Event) -> Void
    var showSession: (String) -> Void
    var close: (() -> Void)?

    @State private var expanded = false
    @State private var showAllLoads = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if !row.summary.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.summary).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                        .lineLimit(expanded ? nil : 3).fixedSize(horizontal: false, vertical: true)
                    if row.summary.count > 180 {
                        Button(expanded ? "Less" : "More") { expanded.toggle() }
                            .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
                    }
                }
            }
            stats
            callouts
            if row.isUsed {
                Hairline()
                trend
                Hairline()
                whoAndWhere
                Hairline()
                outcomes
            }
            if !row.copies.isEmpty {
                Hairline()
                copies
                ForEach(versionCopies) { copy in
                    Hairline()
                    versions(copy)
                }
            }
            if !events.isEmpty {
                Hairline()
                recentLoads
            }
        }
        .bridgeCard(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.skills.detail")
    }

    // Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            SkillMonogram(name: row.name, providers: row.installedFor.isEmpty ? row.usedBy : row.installedFor, size: 40, dimmed: false)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.name).font(BridgeFont.title).foregroundStyle(BridgeTheme.textPrimary)
                    .lineLimit(2).textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                Text(SkillPresentation.originLine(row)).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(2)
            }
            Spacer(minLength: 6)
            if let path = row.primary?.path {
                Menu {
                    SkillPortraitMenu(name: row.name)
                    Divider()
                    Button("Open SKILL.md") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    Divider()
                    Button("Copy skill name") { copyToPasteboard(row.name) }
                    Button("Copy path") { copyToPasteboard(path) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(BridgeTheme.textSecondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Choose picture, open, reveal or copy")
                .accessibilityLabel("Skill actions")
            }
            if let close {
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(BridgeIconButtonStyle(size: 24))
                    .help("Close details").accessibilityLabel("Close skill details")
            }
        }
    }

    // Stats

    private var stats: some View {
        HStack(spacing: 0) {
            stat(row.loads > 0 ? row.loads.formatted() : "—", "Loads",
                 row.sessions > 0 ? "in \(row.sessions) \(row.sessions == 1 ? "session" : "sessions")" : "none in \(periodPhrase)")
            divider
            stat(row.lastUsed.map { ActivityFormat.relative($0, now: to) } ?? "—", "Last used",
                 row.lastUsed.map { $0.formatted(.dateTime.day().month(.abbreviated).hour().minute()) } ?? "not in this period")
            divider
            stat(row.tokensPerLoad.map { "≈" + SkillReport.tokens($0) } ?? "—", "Tokens a load",
                 row.tokensPerLoadMeasured ? "as loaded" : (row.tokensPerLoad == nil ? "size unknown" : "from file size"))
        }
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
        .bridgeWell(cornerRadius: 9)
    }

    private var divider: some View { Rectangle().fill(BridgeTheme.separator).frame(width: 1).padding(.vertical, 4) }

    private func stat(_ value: String, _ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(BridgeTheme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    // Callouts

    @ViewBuilder private var callouts: some View {
        let missing = row.missingSessions.sorted { $0.value > $1.value }
        if !missing.isEmpty || row.copiesDiffer || rereadHeavy {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(missing.map(\.key), id: \.self) { agent in
                    let count = row.missingSessions[agent] ?? 0
                    let source = row.copies.first { $0.scope.isOwned }
                    CalloutBanner(tone: .warning, title: "\(SkillReport.providerName(agent)) can't load this skill",
                                  detail: "\(SkillReport.providerName(agent)) had \(count) \(count == 1 ? "session" : "sessions") in the projects where it was used. Copy \(source.map { SkillPresentation.homeRelative(URL(fileURLWithPath: $0.path).deletingLastPathComponent().path) } ?? "the skill folder") to \(agent == .claude ? "~/.claude/skills" : "~/.codex/skills") to share it.",
                                  icon: "arrow.left.arrow.right", compact: true)
                }
                if row.copiesDiffer {
                    CalloutBanner(tone: .warning, title: "The Claude and Codex copies differ",
                                  detail: "Each agent follows different instructions for this skill. Compare the copies below.",
                                  icon: "arrow.triangle.branch", compact: true)
                }
                if rereadHeavy, let perSession = row.loadsPerSession {
                    CalloutBanner(tone: .notable, title: "Re-read about \(perSession.formatted(.number.precision(.fractionLength(1))))× per session",
                                  detail: "A shorter SKILL.md, with detail moved into reference files the agent opens only when needed, costs less each time.",
                                  icon: "arrow.clockwise", compact: true)
                }
            }
        }
    }

    private var rereadHeavy: Bool { row.isRereadHeavy }

    // Trend

    private var trend: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Loads over \(periodPhrase)", icon: "chart.bar")
            MiniBars(values: row.buckets.map { Double($0) }, tint: BridgeTheme.brand, emptyIndices: [], height: 40)
            if let first = bucketStarts.first, let last = bucketStarts.last {
                HStack {
                    Text(label(first)); Spacer(); Text(hourly ? "Now" : "Today")
                }
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                .accessibilityHidden(true)
                .id(last)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loads over \(periodPhrase): \(row.loads), peak \(row.buckets.max() ?? 0) in one \(hourly ? "hour" : "day")")
    }

    private func label(_ date: Date) -> String {
        hourly ? date.formatted(.dateTime.hour()) : date.formatted(.dateTime.day().month(.abbreviated))
    }

    // Who and where

    private var whoAndWhere: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Who loads it, and where", icon: "person.2")
            let agents = row.loadsByProvider.filter { $0.value > 0 }.sorted { $0.value > $1.value }
                .map { Share(id: $0.key.rawValue, label: SkillReport.providerName($0.key), count: $0.value, color: BridgeTheme.color(for: $0.key)) }
            ShareBar(parts: agents)
            FlowRow(spacing: 12) {
                ForEach(agents) { agent in ShareLegend(part: agent) }
            }
            VStack(spacing: 6) {
                ForEach(row.projects.prefix(4)) { share in
                    HStack(spacing: 8) {
                        Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(BridgeTheme.textTertiary).frame(width: 14)
                        Text(share.path.map { projectLabels[$0] ?? URL(fileURLWithPath: $0).lastPathComponent } ?? "No project")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                            .frame(width: 130, alignment: .leading)
                            .help(share.path ?? "")
                        GeometryReader { proxy in
                            Capsule().fill(BridgeTheme.brand.opacity(0.55))
                                .frame(width: max(3, proxy.size.width * CGFloat(share.loads) / CGFloat(max(1, row.projects.first?.loads ?? 1))))
                                .frame(maxHeight: .infinity)
                        }
                        .frame(height: 5)
                        Text(share.loads.formatted()).font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                            .frame(minWidth: 26, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
                if row.projects.count > 4 {
                    Text("+ \(row.projects.count - 4) more \(row.projects.count - 4 == 1 ? "project" : "projects")")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // Outcomes

    private var outcomes: some View {
        let o = row.outcomes
        let parts = [
            Share(id: "finished", label: "Finished", count: o.finished, color: BridgeTheme.success),
            Share(id: "failed", label: "Failed", count: o.failed, color: BridgeTheme.danger),
            Share(id: "interrupted", label: "Interrupted", count: o.interrupted, color: BridgeTheme.warning),
            Share(id: "open", label: "In progress", count: o.inProgress, color: BridgeTheme.brand),
            Share(id: "unknown", label: "Not recorded", count: o.unknown, color: BridgeTheme.textTertiary),
        ].filter { $0.count > 0 }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                SectionTitle(text: "Turns that loaded it", icon: "checklist")
                InfoButton(title: "Turns that loaded it", text: "How the turns that loaded this skill ended, and what changed in the sessions around them. Claude Code records each model request separately, so its turns often show no final status. These describe work that happened alongside the skill; they don't prove the skill caused it.")
            }
            if o.total > 0 {
                ShareBar(parts: parts)
                FlowRow(spacing: 12) {
                    ForEach(parts) { part in ShareLegend(part: part) }
                }
            }
            HStack(spacing: 16) {
                if let median = row.medianTurnSeconds { miniFact(ActivityFormat.duration(median), "median turn", "timer") }
                // No recorded change isn't proof of none, so a zero isn't shown.
                if row.sessionFilesChanged > 0 {
                    miniFact(row.sessionFilesChanged.formatted(), row.sessionFilesChanged == 1 ? "file changed in its sessions" : "files changed in its sessions", "doc.badge.ellipsis")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func miniFact(_ value: String, _ label: String, _ icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(BridgeTheme.textTertiary)
            Text(value).font(BridgeFont.numeral).foregroundStyle(BridgeTheme.textPrimary)
            Text(label).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
        }
    }

    // Copies

    private var copies: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: row.copies.count == 1 ? "Installed copy" : "Installed copies · \(row.copies.count)", icon: "doc.on.doc")
            ForEach(row.copies) { copy in
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.path)]) } label: {
                    HStack(alignment: .top, spacing: 9) {
                        AgentAvatar(name: copy.provider.rawValue.capitalized, size: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(SkillPresentation.copyTitle(copy)).font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textPrimary)
                                if let modified = copy.modifiedAt {
                                    Text("edited \(ActivityFormat.relative(modified, now: fileClock))").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                                }
                            }
                            Text(SkillPresentation.homeRelative(copy.path)).font(BridgeFont.mono).foregroundStyle(BridgeTheme.textTertiary)
                                .lineLimit(1).truncationMode(.middle)
                            Text(SkillPresentation.sizeLine(copy)).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.forward.square").font(.system(size: 10)).foregroundStyle(BridgeTheme.textTertiary)
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverRowButtonStyle())
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .help("Show in Finder: \(copy.path)")
                .contextMenu {
                    Button("Open SKILL.md") { NSWorkspace.shared.open(URL(fileURLWithPath: copy.path)) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: copy.path)]) }
                    Button("Copy path") { copyToPasteboard(copy.path) }
                }
            }
        }
    }

    // Versions

    /// Files can change after the snapshot the page shows; date them by the clock.
    private var fileClock: Date { max(to, Date()) }

    /// Your own copies (one per agent), else the copy agents load.
    private var versionCopies: [InstalledSkill] {
        let owned = row.copies.filter { $0.scope.isOwned }
        var seen = Set<AgentName>()
        let picked = (owned.isEmpty ? Array(row.copies.prefix(1)) : owned).filter { seen.insert($0.provider).inserted }
        return Array(picked.prefix(2))
    }

    private func versions(_ copy: InstalledSkill) -> some View {
        let changes = ContextFileTimeline.changes(path: copy.path, record: history[copy.path], repositories: repositories, now: fileClock)
        let title = versionCopies.count > 1 ? "Versions · \(SkillReport.providerName(copy.provider)) copy" : "Versions"
        return ContextChangesView(
            title: title, changes: changes,
            usage: { change in
                allLoads.filter { $0.provider == copy.provider && $0.timestamp >= change.date && $0.timestamp < (change.validUntil ?? to) }.count
            },
            usageNoun: { $0 == 1 ? "load" : "loads" }, now: fileClock,
            info: "Each version of this SKILL.md the Hub has seen, with lines added and removed since the one before, plus Git commits that changed it when its folder is in a scanned repository. Loads count \(SkillReport.providerName(copy.provider))'s loads in \(periodPhrase) while each version was current. Only line counts and fingerprints are kept, never the text.")
    }

    // Recent loads

    private var recentLoads: some View {
        let shown = showAllLoads ? events : Array(events.prefix(6))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                SectionTitle(text: "Recent loads", icon: "clock.arrow.circlepath")
                Spacer()
                Text("Click to inspect the turn").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            }
            VStack(spacing: 1) {
                ForEach(shown) { event in loadRow(event) }
            }
            if events.count > 6 {
                Button(showAllLoads ? "Show fewer" : "Show \(events.count - 6) more") { showAllLoads.toggle() }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
            }
        }
    }

    private func loadRow(_ event: SkillReport.Event) -> some View {
        let session = sessions[event.sessionID]
        let parent = session?.parentSessionID.flatMap { sessions[$0] }
        let title = session.map { ActivityTitles.display($0.title, provider: $0.provider, projectPath: $0.projectPath, parentTitle: parent?.title) } ?? "Session"
        return Button { inspect(event) } label: {
            HStack(spacing: 8) {
                Text(timeLabel(event.timestamp)).font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                    .lineLimit(1).frame(width: 74, alignment: .leading)
                AgentAvatar(name: event.provider.rawValue.capitalized, size: 12)
                Text(title).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                if event.trigger == .command {
                    Text("/").font(BridgeFont.micro.monospaced()).foregroundStyle(BridgeTheme.brand).help("Started with a slash command")
                }
                Image(systemName: TurnStatusBadge.symbol(event.turnStatus)).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TurnStatusBadge.color(event.turnStatus)).help(event.turnStatus.title)
            }
            .padding(.horizontal, 6).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contextMenu {
            Button("Inspect turn") { inspect(event) }
            Button("Session details") { showSession(event.sessionID) }
        }
        .accessibilityLabel("\(title), \(timeLabel(event.timestamp)), \(event.turnStatus.title)")
        .accessibilityHint("Inspect this turn")
    }

    /// "14:05" today, "5 Nov 22:46" before.
    private func timeLabel(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        return Calendar.current.isDate(date, inSameDayAs: to) ? time : "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Shared pieces

struct Share: Identifiable {
    var id: String
    var label: String
    var count: Int
    var color: Color
}

/// Proportional segments with 2pt gaps; every non-zero part stays visible.
struct ShareBar: View {
    var parts: [Share]

    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.count })
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(parts) { part in
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(part.color.opacity(part.id == "unknown" ? 0.5 : 0.9))
                        .frame(width: max(4, (proxy.size.width - CGFloat(max(0, parts.count - 1)) * 2) * CGFloat(part.count) / CGFloat(total)))
                }
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

struct ShareLegend: View {
    var part: Share

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(part.color).frame(width: 7, height: 7)
            Text(part.label).foregroundStyle(BridgeTheme.textSecondary)
            Text(part.count.formatted()).monospacedDigit().foregroundStyle(BridgeTheme.textPrimary)
        }
        .font(BridgeFont.caption)
        .accessibilityElement(children: .combine)
    }
}

/// Lays children out left to right, wrapping when they don't fit.
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}

enum SkillPresentation {
    static func scopeLabel(_ row: SkillReport.Row) -> String {
        guard let scope = row.scope else { return "Seen in use" }
        return scope.title
    }

    /// "Personal skill · Claude and Codex", "Plugin figma · Codex".
    static func originLine(_ row: SkillReport.Row) -> String {
        let agents = (row.installedFor.isEmpty ? row.usedBy : row.installedFor).map(SkillReport.providerName)
        let who = agents.count == 2 ? "\(agents[0]) and \(agents[1])" : agents.first ?? "No agent"
        guard let primary = row.primary else { return "Loaded by \(who) · not in a folder the Hub reads" }
        switch primary.scope {
        case .personal: return "Personal skill · \(who)"
        case .project: return "Project skill · \(primary.owner.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "project") · \(who)"
        case .plugin: return "From the \(primary.owner ?? "") plugin · \(who)"
        case .system: return "Built into \(SkillReport.providerName(primary.provider)) · \(who)"
        }
    }

    static func copyTitle(_ copy: InstalledSkill) -> String {
        let agent = SkillReport.providerName(copy.provider)
        switch copy.scope {
        case .personal: return "\(agent) · Personal"
        case .project: return "\(agent) · \(copy.owner.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Project")"
        case .plugin: return "\(agent) · \(copy.owner ?? "Plugin") plugin"
        case .system: return "\(agent) · Built in"
        }
    }

    static func sizeLine(_ copy: InstalledSkill) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(copy.bytes), countStyle: .file), "≈\(SkillReport.tokens(copy.loadTokens)) tokens"]
        if copy.supportingFiles > 0 { parts.append("\(copy.supportingFiles) supporting \(copy.supportingFiles == 1 ? "file" : "files")") }
        return parts.joined(separator: " · ")
    }

    static func homeRelative(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path.replacingOccurrences(of: "/Users/[REDACTED]", with: "~")
    }
}
