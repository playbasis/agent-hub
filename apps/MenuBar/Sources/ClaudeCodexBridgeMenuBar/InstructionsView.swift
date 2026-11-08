import AppKit
import BridgeCore
import SwiftUI

/// Reads instruction files while the Instructions view is open. The reader
/// is an actor with its own cache, so returning to the view is instant.
@MainActor final class InstructionCatalogModel: ObservableObject {
    /// One per app, so leaving and reopening the view keeps the catalog.
    static let shared = InstructionCatalogModel()
    @Published private(set) var catalog: InstructionCatalog?
    @Published private(set) var isReading = false

    func refresh(projects: [String]) async {
        isReading = true
        let value = await InstructionCatalogReader.shared.catalog(projects: projects)
        if catalog?.revision != value.revision { catalog = value }
        isReading = false
    }
}

/// The Skills page's two views: skills an agent loads on demand, and the
/// instruction files (AGENTS.md, CLAUDE.md, rules, memory) it always loads.
struct SkillsPage: View {
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
    @Binding var showsInstructions: Bool
    @Binding var skillSelection: String?
    @Binding var instructionSelection: String?
    var showSession: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SkillsModePicker(showsInstructions: $showsInstructions)
            if showsInstructions {
                InstructionsView(sessions: sessions, overview: overview, revision: revision, from: from, to: to, hourly: hourly,
                                 periodPhrase: periodPhrase, provider: provider, project: project, query: query,
                                 catalogProjects: catalogProjects, projectLabels: projectLabels,
                                 selection: $instructionSelection, showSession: showSession,
                                 showSkills: { withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.15)) { showsInstructions = false } })
            } else {
                SkillsView(sessions: sessions, overview: overview, revision: revision, from: from, to: to, hourly: hourly,
                           periodPhrase: periodPhrase, provider: provider, project: project, query: query,
                           catalogProjects: catalogProjects, projectLabels: projectLabels,
                           selection: $skillSelection, showSession: showSession)
            }
        }
    }
}

/// Two-way switch between the views, sized to its labels.
private struct SkillsModePicker: View {
    @Binding var showsInstructions: Bool

    var body: some View {
        HStack(spacing: 2) {
            option("Skills", icon: "wand.and.stars", help: "Skills: instructions an agent loads when a task calls for them", selected: !showsInstructions) {
                showsInstructions = false
            }
            option("Instructions", icon: "doc.text", help: "AGENTS.md, CLAUDE.md, rules and memory: what an agent loads in every session", selected: showsInstructions) {
                showsInstructions = true
            }
        }
        .padding(3)
        .background(BridgeTheme.well, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(BridgeTheme.wellBorder, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Skills page view")
    }

    private func option(_ title: String, icon: String, help: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.15)) { action() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected ? BridgeTheme.brand : BridgeTheme.textTertiary)
                Text(title)
            }
            .font(BridgeFont.secondaryMedium)
            .foregroundStyle(selected ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
            .padding(.horizontal, 12).frame(height: 26)
            .background(selected ? BridgeTheme.controlPressed : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
    }
}

/// What every session starts with, per project: which instruction files
/// each agent reads, whether both get the same rules, what that costs, and
/// what changed.
struct InstructionsView: View {
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
    var showSkills: () -> Void

    @ObservedObject private var catalogModel = InstructionCatalogModel.shared
    @State private var report: InstructionReport.Result?
    /// The last report built, shown at once when the view is reopened with the
    /// same filters while a newer snapshot's report is built.
    @MainActor private static var lastReport: (key: ReportKey, result: InstructionReport.Result)?
    @State private var filter: InstructionFilter = .all
    @State private var width: CGFloat = 0
    @FocusState private var listFocused: Bool
    @Environment(\.activityContentVisible) private var contentVisible

    private static let sideBySideWidth: CGFloat = 960
    private static let listHeight: CGFloat = 560

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

    private var shownReport: InstructionReport.Result? {
        report ?? Self.lastReport.flatMap { $0.key.sameSelection(as: key) ? $0.result : nil }
    }

    private var key: ReportKey {
        ReportKey(revision: revision, from: from, to: to, provider: provider, project: project, hourly: hourly,
                  catalog: catalogModel.catalog?.revision ?? "pending")
    }

    /// Every folder a session worked in, plus the projects the Hub knows.
    private var scanProjects: [String] {
        Array(Set(catalogProjects + sessions.compactMap(\.projectPath))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let report = shownReport, catalogModel.catalog != nil {
                if report.rows.isEmpty {
                    emptyState
                } else {
                    summary(report)
                    if !report.insights.isEmpty { insights(report) }
                    if !report.starts.isEmpty { StartLoadCard(starts: report.starts, periodPhrase: periodPhrase, showSkills: showSkills) }
                    library(report)
                }
            } else {
                ActivityLoadingView(page: .skills, message: "Reading instruction files…")
            }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { width = $0 }
        })
        .task(id: key) { await rebuild(key) }
        .task(id: scanProjects) {
            // Instruction files change rarely; check once a minute while visible.
            while !Task.isCancelled {
                if contentVisible { await catalogModel.refresh(projects: scanProjects) }
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.instructions")
    }

    private func rebuild(_ key: ReportKey) async {
        guard let catalog = catalogModel.catalog else { return }
        let input = InstructionReport.Input(sessions: sessions, catalog: catalog, from: from, to: to,
                                            provider: provider, project: project, hourly: hourly)
        if let last = Self.lastReport, last.key == key { report = last.result; return }
        let result = await Task.detached(priority: .userInitiated) { InstructionReport.build(input) }.value
        guard !Task.isCancelled else { return }
        report = result
        Self.lastReport = (key, result)
    }

    // MARK: Empty

    private var emptyState: some View {
        HubEmptyState(
            icon: "doc.text",
            title: "No sessions in this period",
            message: "Instruction files are the rules an agent reads at the start of every session: AGENTS.md for Codex, and CLAUDE.md (or AGENTS.md when there's no CLAUDE.md) for Claude Code. Once an agent works in a project, what it read shows up here.")
    }

    // MARK: Summary

    private func summary(_ report: InstructionReport.Result) -> some View {
        let totals = report.totals
        let perSession = report.starts.map { start -> String in
            "\(SkillReport.providerName(start.agent)) ≈\(InstructionPresentation.tokens(start.instructions))"
        }.joined(separator: " · ")
        let typical = ActivityMetrics.median(report.starts.flatMap { start in Array(repeating: Double(start.instructions), count: max(1, start.sessions)) })
        let without = totals.projects - totals.projectsWithRules
        let recorded = totals.sessions > 0 ? Int((Double(totals.measuredSessions) / Double(totals.sessions) * 100).rounded()) : 0
        return MetricStrip(items: [
            MetricItem(title: "Projects with rules", icon: "doc.text",
                       value: "\(totals.projectsWithRules) of \(totals.projects)",
                       footnote: without > 0 ? "\(without) without" : "All have rules",
                       info: "Projects your agents worked in during \(periodPhrase) that have instruction files of their own: AGENTS.md, CLAUDE.md, CLAUDE.local.md or rules in .claude/rules. Your personal files, such as ~/.codex/AGENTS.md, apply to every project and are shown separately."),
            MetricItem(title: "Same for both agents", icon: "arrow.left.arrow.right",
                       value: totals.projectsWithRules > 0 ? "\(totals.projectsSame) of \(totals.projectsWithRules)" : "—",
                       footnote: totals.projectsDiffer > 0 ? "\(totals.projectsDiffer) \(totals.projectsDiffer == 1 ? "needs" : "need") a look"
                           : (totals.projectsWithRules > 0 ? "All match" : "No project rules yet"),
                       info: "Whether Claude Code and Codex read the same project rules. Claude Code reads CLAUDE.md, or AGENTS.md when there's no CLAUDE.md; Codex reads AGENTS.md. A CLAUDE.md that only says @AGENTS.md shares AGENTS.md's rules."),
            MetricItem(title: "Rules a session", icon: "text.alignleft",
                       value: typical.map { "≈" + InstructionPresentation.tokens(Int($0)) } ?? "—",
                       footnote: perSession.isEmpty ? "Tokens of instructions" : perSession,
                       info: "Typical tokens of instruction files a session starts with: project rules, your personal rules and Claude's memory. It stays in context for every request in the session."),
            MetricItem(title: "Rules loaded", icon: "tray.full",
                       value: "≈" + InstructionPresentation.tokens(totals.charactersLoaded),
                       footnote: "\(totals.sessions.formatted()) \(totals.sessions == 1 ? "session" : "sessions") · \(recorded)% recorded",
                       info: report.coverage.joined(separator: "\n\n"),
                       series: report.loadSeries.map { Double($0) }),
            MetricItem(title: "Changes", icon: "pencil.line",
                       value: totals.edits > 0 ? totals.edits.formatted() : (totals.filesChanged > 0 ? totals.filesChanged.formatted() : "None"),
                       footnote: totals.edits > 0 ? "\(totals.edits == 1 ? "edit" : "edits") by agents · \(totals.filesChanged) \(totals.filesChanged == 1 ? "file" : "files") changed"
                           : (totals.filesChanged > 0 ? "\(totals.filesChanged == 1 ? "file" : "files") changed on disk" : "No rule changes"),
                       info: "Agent edits to instruction files recorded in \(periodPhrase), and instruction files modified on disk in the same period by anyone. A change applies from the next session that starts in the project."),
        ], tint: BridgeTheme.brand)
    }

    // MARK: Insights

    private func insights(_ report: InstructionReport.Result) -> some View {
        HighlightsSection(periodPhrase: periodPhrase,
                          info: "Picked from what each session recorded at its start and the instruction files on this Mac. Amber is worth a look, cyan is unusual, green is good news. Hover a card to see how it was measured; click it to open the project.",
                          items: report.insights.map(\.highlight), minimumWidth: 210) { highlight in
            report.insights.first { $0.highlight.id == highlight.id }?.projectKey.map { key in { select(key) } }
        }
    }

    // MARK: Library

    private func library(_ report: InstructionReport.Result) -> some View {
        let rows = visibleRows(report)
        let selected = report.row(selection) ?? (width >= Self.sideBySideWidth ? rows.first : nil)
        return Group {
            if width >= Self.sideBySideWidth {
                HStack(alignment: .top, spacing: 14) {
                    libraryCard(report, rows: rows, selectedID: selected?.id).frame(maxWidth: .infinity, alignment: .topLeading)
                    detail(selected, report: report).frame(width: min(440, max(370, width * 0.38)))
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    libraryCard(report, rows: rows, selectedID: selected?.id)
                    if selected != nil { detail(selected, report: report) }
                }
            }
        }
    }

    @ViewBuilder private func detail(_ row: InstructionReport.ProjectRow?, report: InstructionReport.Result) -> some View {
        if let row, let catalog = catalogModel.catalog {
            InstructionDetailPanel(row: row, catalog: catalog, bucketStarts: report.bucketStarts, hourly: report.hourly,
                                   periodPhrase: periodPhrase, to: to, label: label(row), sessions: sessionIndex,
                                   repositories: overview.repositories,
                                   inspect: inspect, showSession: showSession,
                                   close: width >= Self.sideBySideWidth ? nil : { selection = nil })
                .id(row.id)
                .transition(.opacity)
        }
    }

    private var sessionIndex: [String: ActivitySession] {
        Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { lhs, rhs in lhs.observedAt >= rhs.observedAt ? lhs : rhs })
    }

    private func label(_ row: InstructionReport.ProjectRow) -> String {
        row.isPersonal ? "Every project" : projectLabels[row.id] ?? URL(fileURLWithPath: row.id).lastPathComponent
    }

    private func libraryCard(_ report: InstructionReport.Result, rows: [InstructionReport.ProjectRow], selectedID: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { libraryTitle(report); Spacer(minLength: 10); filters(report) }
                VStack(alignment: .leading, spacing: 8) { libraryTitle(report); filters(report) }
            }
            if rows.isEmpty {
                Text(query.isEmpty ? "No projects match this filter." : "No projects match “\(query)”.")
                    .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(rows) { row in
                                InstructionProjectRowView(row: row, label: label(row), catalog: catalogModel.catalog,
                                                          selected: row.id == selectedID, compact: width < 640, select: { select(row.id) })
                                    .id(row.id)
                            }
                        }
                        .padding(4)
                    }
                    .frame(height: min(CGFloat(rows.count) * 55 + 7, Self.listHeight))
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
        .accessibilityIdentifier("bridge.instructions.projects")
    }

    private func libraryTitle(_ report: InstructionReport.Result) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "folder").font(.system(size: 12, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary)
            Text("Where your agents work").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
            Text("\(report.totals.projects) \(report.totals.projects == 1 ? "project" : "projects")").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            if catalogModel.isReading { ProgressView().controlSize(.mini) }
            InfoButton(title: "Where your agents work", text: (catalogModel.catalog?.notes ?? []).joined(separator: "\n\n"))
        }
        .fixedSize()
    }

    private func filters(_ report: InstructionReport.Result) -> some View {
        HStack(spacing: 4) {
            ForEach(InstructionFilter.allCases) { option in
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

    private func visibleRows(_ report: InstructionReport.Result) -> [InstructionReport.ProjectRow] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        var rows = report.rows.filter { filter.matches($0) }
        if !needle.isEmpty {
            rows = rows.filter { row in
                label(row).localizedCaseInsensitiveContains(needle) || row.id.localizedCaseInsensitiveContains(needle)
            }
        }
        return rows
    }

    private func select(_ key: String) {
        withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.15)) { selection = key }
        if filter != .all, report?.row(key).map({ filter.matches($0) }) == false { filter = .all }
        listFocused = true
    }

    private func inspect(_ edit: InstructionReport.Edit) {
        Task { @MainActor in
            ActivityReportsController.shared.inspectTurn(overview: overview, sessionID: edit.sessionID, turnID: edit.turnID, snapshotRevision: revision)
        }
    }
}

// MARK: - Filters

enum InstructionFilter: String, CaseIterable, Identifiable {
    case all, attention, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .attention: return "Needs a look"
        case .none: return "No rules"
        }
    }
    var help: String {
        switch self {
        case .all: return "Every project your agents worked in during this period"
        case .attention: return "The agents read different rules, one worked without the project's rules, or Codex can't read all of it"
        case .none: return "Projects with no instruction files of their own"
        }
    }
    func matches(_ row: InstructionReport.ProjectRow) -> Bool {
        switch self {
        case .all: return true
        case .attention: return row.needsLook
        case .none: return !row.isPersonal && row.parity == .none
        }
    }
}

// MARK: - Start load

/// What each agent carries before the first message, part by part, on one
/// scale so the agents compare at a glance.
private struct StartLoadCard: View {
    var starts: [InstructionReport.AgentStart]
    var periodPhrase: String
    var showSkills: () -> Void

    var body: some View {
        let scale = max(1, starts.map(\.total).max() ?? 1)
        let parts = InstructionReport.Part.allCases.filter { part in starts.contains { ($0.parts[part] ?? 0) > 0 } }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "text.badge.star").font(.system(size: 12, weight: .semibold)).foregroundStyle(BridgeTheme.brand)
                Text("Before your first message").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                Text("· typical session, \(periodPhrase)").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textTertiary)
                InfoButton(title: "Before your first message", text: "The median size of what each agent was given at the start of a session in this period, as the agent recorded it: project rules, your own rules, Claude's memory and the list of skills it can load. All of it stays in context for every request. Where a session's record isn't available, the instruction files on disk are used.")
                Spacer(minLength: 0)
            }
            VStack(spacing: 10) {
                ForEach(starts) { start in agentRow(start, scale: scale) }
            }
            HStack(spacing: 14) {
                FlowRow(spacing: 14) {
                    ForEach(parts, id: \.self) { part in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(BridgeTheme.startPart(part)).frame(width: 8, height: 8)
                            Text(part.title).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                if let takeaway {
                    Button(action: showSkills) {
                        HStack(spacing: 4) {
                            Text(takeaway)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
                    .help("Open the skill list on the Skills view")
                    .fixedSize()
                }
            }
        }
        .bridgeCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.instructions.start")
    }

    /// Points at the skill list when it's most of what a session carries.
    private var takeaway: String? {
        guard let top = starts.max(by: { ($0.parts[.skills] ?? 0) < ($1.parts[.skills] ?? 0) }),
              let skills = top.parts[.skills], top.total > 0 else { return nil }
        let share = Double(skills) / Double(top.total)
        guard share >= 0.5 else { return nil }
        return "Skill list is \(Int((share * 100).rounded()))% of \(SkillReport.providerName(top.agent))'s start"
    }

    private func agentRow(_ start: InstructionReport.AgentStart, scale: Int) -> some View {
        HStack(spacing: 10) {
            AgentAvatar(name: start.agent.rawValue.capitalized, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(start.agent == .claude ? "Claude Code" : "Codex").font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textPrimary)
                Text(start.measuredSessions > 0 ? "\(start.measuredSessions) of \(start.sessions) recorded" : "from files on disk")
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
            }
            .frame(width: 104, alignment: .leading)
            GeometryReader { proxy in
                let available = max(0, proxy.size.width)
                let segments = InstructionReport.Part.allCases.compactMap { part -> (InstructionReport.Part, Int)? in
                    guard let value = start.parts[part], value > 0 else { return nil }
                    return (part, value)
                }
                HStack(spacing: 2) {
                    ForEach(segments, id: \.0) { part, value in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(BridgeTheme.startPart(part).opacity(0.9))
                            .frame(width: max(3, available * CGFloat(value) / CGFloat(scale) - 2))
                            .help("\(part.title) ≈\(InstructionPresentation.tokens(value)) tokens")
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 12)
            Text("≈" + InstructionPresentation.tokens(start.total))
                .font(BridgeFont.numeral).foregroundStyle(BridgeTheme.textPrimary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(start.agent == .claude ? "Claude Code" : "Codex") starts with about \(InstructionPresentation.tokens(start.total)) tokens: "
            + InstructionReport.Part.allCases.compactMap { part in start.parts[part].map { "\(part.title) \(InstructionPresentation.tokens($0))" } }.joined(separator: ", "))
    }
}

// MARK: - Row

/// One project: what both agents read there, how much, and how often.
private struct InstructionProjectRowView: View {
    var row: InstructionReport.ProjectRow
    var label: String
    var catalog: InstructionCatalog?
    var selected: Bool
    var compact: Bool
    var select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 11) {
                ProjectTile(row: row, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(label).font(BridgeFont.bodyMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1).truncationMode(.middle)
                        if row.needsLook {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(BridgeTheme.warning)
                                .help("Needs a look: open the project to see why")
                        }
                    }
                    Text(InstructionPresentation.summary(row, catalog: catalog))
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                agentMarks
                if !compact && !row.isPersonal {
                    MiniBars(values: row.buckets.map { Double($0) }, tint: BridgeTheme.brand, emptyIndices: [], height: 18)
                        .frame(width: 64)
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(row.totalSessions > 0 ? row.totalSessions.formatted() : "—")
                        .font(BridgeFont.numeral).foregroundStyle(BridgeTheme.textPrimary)
                    Text(row.totalSessions == 1 ? "session" : "sessions")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                }
                .frame(width: 56, alignment: .trailing)
            }
            .padding(.horizontal, 10).frame(height: 54)
            .background(selected ? BridgeTheme.brand.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? BridgeTheme.brand.opacity(0.45) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(InstructionPresentation.summary(row, catalog: catalog)), \(row.totalSessions) sessions\(row.needsLook ? ", needs a look" : "")")
        .accessibilityHint("Show what each agent reads")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : [.isButton])
    }

    /// Each agent with its rules a session; an amber ring where it worked without them.
    private var agentMarks: some View {
        HStack(spacing: 8) {
            ForEach([AgentName.claude, .codex], id: \.self) { agent in
                let chain = row.instructions?.chain(agent)
                let reads = row.isPersonal ? !(chain?.links.isEmpty ?? true) : !(chain?.projectLinks.isEmpty ?? true)
                let worked = (row.sessions[agent] ?? 0) > 0
                let missing = row.missingSessions[agent] != nil || (agent == .claude && row.olderClaudeSessions > 0)
                HStack(spacing: 4) {
                    if missing {
                        Circle().strokeBorder(BridgeTheme.warning, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])).frame(width: 13, height: 13)
                    } else {
                        AgentAvatar(name: agent.rawValue.capitalized, size: 13, dimmed: !reads)
                    }
                    Text(row.perSession[agent].map { "≈" + InstructionPresentation.tokens($0) } ?? (reads ? "≈" + InstructionPresentation.tokens(chainCharacters(chain)) : "—"))
                        .font(BridgeFont.micro.monospacedDigit())
                        .foregroundStyle(worked ? BridgeTheme.textSecondary : BridgeTheme.textTertiary)
                        .frame(minWidth: 34, alignment: .leading)
                }
                .help(markHelp(agent, reads: reads, worked: worked, missing: missing))
            }
        }
    }

    private func chainCharacters(_ chain: InstructionChain?) -> Int {
        guard let chain else { return 0 }
        return (row.isPersonal ? chain.links : chain.projectLinks).reduce(0) { total, link in
            total + (catalog?.file(link.path)?.characters ?? link.bytesRead)
        }
    }

    private func markHelp(_ agent: AgentName, reads: Bool, worked: Bool, missing: Bool) -> String {
        let name = SkillReport.providerName(agent)
        if missing { return "\(name) worked here without the project's rules" }
        if let value = row.perSession[agent] {
            return "\(name): ≈\(InstructionPresentation.tokens(value)) tokens of rules a session\(row.perSessionMeasured[agent] == true ? ", as recorded" : ", from the files")"
        }
        return reads ? "\(name) reads rules here; no sessions in this period" : "\(name) has no rules here"
    }
}

/// A project's mark: a folder tinted by whether both agents share its rules.
private struct ProjectTile: View {
    var row: InstructionReport.ProjectRow
    var size: CGFloat

    var body: some View {
        let tint = row.isPersonal ? BridgeTheme.brandDeep : (row.needsLook ? BridgeTheme.warning : BridgeTheme.parity(row.parity))
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.opacity(row.parity == .none && !row.isPersonal ? 0.12 : 0.2))
            Image(systemName: row.isPersonal ? "person.crop.circle" : (row.parity == .none ? "folder" : "folder.fill"))
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(row.parity == .none && !row.isPersonal ? BridgeTheme.textTertiary : tint)
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

// MARK: - Detail

/// Everything about one project's rules: whether both agents share them,
/// which files each one reads and why, what they cost, and agent edits.
private struct InstructionDetailPanel: View {
    var row: InstructionReport.ProjectRow
    var catalog: InstructionCatalog
    var bucketStarts: [Date]
    var hourly: Bool
    var periodPhrase: String
    var to: Date
    var label: String
    var sessions: [String: ActivitySession]
    var repositories: [ActivityRepository]
    var inspect: (InstructionReport.Edit) -> Void
    var showSession: (String) -> Void
    var close: (() -> Void)?

    @State private var showAllEdits = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            callouts
            stats
            Hairline()
            ForEach([AgentName.claude, .codex], id: \.self) { agent in
                if let chain = row.instructions?.chain(agent) { chainSection(agent, chain: chain) }
            }
            Hairline()
            changes
            if !row.edits.isEmpty {
                Hairline()
                edits
            }
            if !row.isPersonal, row.totalSessions > 0 {
                Hairline()
                trend
            }
        }
        .bridgeCard(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.instructions.detail")
    }

    // Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ProjectTile(row: row, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(BridgeFont.title).foregroundStyle(BridgeTheme.textPrimary)
                    .lineLimit(2).textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                Text(row.isPersonal ? "Your own files, read in every project" : SkillPresentation.homeRelative(row.id))
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(2).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if !row.isPersonal {
                Menu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.id)]) }
                    Button("Copy path") { copyToPasteboard(row.id) }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(BridgeTheme.textSecondary)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Reveal or copy")
                .accessibilityLabel("Project actions")
            }
            if let close {
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(BridgeIconButtonStyle(size: 24))
                    .help("Close details").accessibilityLabel("Close project details")
            }
        }
    }

    // Callouts

    @ViewBuilder private var callouts: some View {
        let banners = InstructionPresentation.banners(row, catalog: catalog)
        if !banners.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(banners) { banner in
                    CalloutBanner(tone: banner.tone, title: banner.title, detail: banner.detail, icon: banner.icon, compact: true)
                }
            }
        }
    }

    // Stats

    private var stats: some View {
        HStack(spacing: 0) {
            stat(row.totalSessions > 0 ? row.totalSessions.formatted() : "—", "Sessions",
                 row.sessions.isEmpty ? "none in \(periodPhrase)"
                     : [AgentName.claude, .codex].compactMap { agent in row.sessions[agent].map { "\(SkillReport.providerName(agent)) \($0)" } }.joined(separator: " · "))
            divider
            agentStat(.claude)
            divider
            agentStat(.codex)
        }
        .padding(.vertical, 10)
        // The dividers would otherwise stretch to the panel's full height.
        .fixedSize(horizontal: false, vertical: true)
        .bridgeWell(cornerRadius: 9)
    }

    private func agentStat(_ agent: AgentName) -> some View {
        let measured = row.perSessionMeasured[agent] == true
        let value = row.perSession[agent] ?? fileCharacters(agent)
        return stat(value > 0 ? "≈" + InstructionPresentation.tokens(value) : "—", "\(SkillReport.providerName(agent)) a session",
                    row.perSession[agent] == nil ? (value > 0 ? "from the files" : "no rules") : (measured ? "as recorded" : "from the files"))
    }

    private func fileCharacters(_ agent: AgentName) -> Int {
        guard let chain = row.instructions?.chain(agent) else { return 0 }
        return (row.isPersonal ? chain.links : chain.links.filter { !$0.isPersonal }).reduce(0) { total, link in
            total + (catalog.file(link.path).map { link.bytesRead >= $0.bytes ? $0.characters : link.bytesRead } ?? link.bytesRead)
        }
    }

    private var divider: some View { Rectangle().fill(BridgeTheme.separator).frame(width: 1).padding(.vertical, 4) }

    private func stat(_ value: String, _ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(BridgeTheme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .combine)
    }

    // What each agent reads

    private func chainSection(_ agent: AgentName, chain: InstructionChain) -> some View {
        let links = row.isPersonal ? chain.links : chain.links
        let other = row.instructions?.chain(agent == .claude ? .codex : .claude)
        let shared = Set((other?.links ?? []).map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                AgentAvatar(name: agent.rawValue.capitalized, size: 14)
                Text(agent == .claude ? "Claude Code reads" : "Codex reads").font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textPrimary)
                Spacer(minLength: 4)
                if !links.isEmpty {
                    Text("≈\(InstructionPresentation.tokens(links.reduce(0) { $0 + characters($1) })) tokens")
                        .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                }
            }
            if links.isEmpty {
                Text(InstructionPresentation.emptyChain(agent, personal: row.isPersonal))
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            } else {
                VStack(spacing: 1) {
                    ForEach(links) { link in
                        fileRow(link, agent: agent, shared: shared.contains(URL(fileURLWithPath: link.path).resolvingSymlinksInPath().path))
                    }
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func characters(_ link: InstructionLink) -> Int {
        catalog.file(link.path).map { link.bytesRead >= $0.bytes ? $0.characters : link.bytesRead } ?? link.bytesRead
    }

    private func fileRow(_ link: InstructionLink, agent: AgentName, shared: Bool) -> some View {
        let file = catalog.file(link.path)
        let cut = file.map { link.bytesRead < $0.bytes } ?? false
        return Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: link.path)]) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: InstructionPresentation.symbol(link))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary)
                    .frame(width: 14).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(InstructionPresentation.fileName(link, project: row.isPersonal ? nil : row.id))
                            .font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1).truncationMode(.head)
                        Tag(text: InstructionPresentation.reason(link, catalog: catalog))
                        if shared && link.reason != .memory {
                            Image(systemName: "link").font(.system(size: 9, weight: .semibold)).foregroundStyle(BridgeTheme.success)
                                .help("Both agents read this file")
                        }
                    }
                    HStack(spacing: 6) {
                        if let file, file.isPointer {
                            Text("Points to \(file.imports.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))")
                        } else if cut, let file {
                            Text("Reads \(InstructionPresentation.kilobytes(link.bytesRead)) of \(InstructionPresentation.kilobytes(file.bytes))")
                                .foregroundStyle(BridgeTheme.warning)
                        } else if let file, file.lines > 0 {
                            Text("\(file.lines) lines")
                        }
                        if let modified = file?.modifiedAt {
                            Text("edited \(ActivityFormat.relative(modified, now: max(to, Date())))")
                        }
                    }
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("≈" + InstructionPresentation.tokens(characters(link)))
                    .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help("Show in Finder: \(link.path)")
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: link.path)) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: link.path)]) }
            Button("Copy path") { copyToPasteboard(link.path) }
        }
        .accessibilityLabel("\(InstructionPresentation.fileName(link, project: row.isPersonal ? nil : row.id)), \(InstructionPresentation.reason(link, catalog: catalog)), about \(InstructionPresentation.tokens(characters(link))) tokens")
    }

    // Changes

    private var claudePaths: Set<String> { Set(row.instructions?.claude.links.filter { $0.reason != .memory }.map(\.path) ?? []) }
    private var codexPaths: Set<String> { Set(row.instructions?.codex.links.filter { $0.reason != .memory }.map(\.path) ?? []) }

    /// Every version of the files either agent reads here, newest first.
    private var changes: some View {
        let claude = claudePaths, codex = codexPaths
        let paths = Array(claude.union(codex)).sorted()
        var timeline: [ContextFileChange] = []
        for path in paths {
            timeline += ContextFileTimeline.changes(path: path, record: catalog.history[path], repositories: repositories, now: max(to, Date()))
        }
        timeline.sort { $0.date == $1.date ? $0.id > $1.id : $0.date > $1.date }
        let starts = Array(sessions.values).filter { row.isPersonal || $0.projectPath == row.id }
        let label: ((String) -> String)? = paths.count > 1 ? { fileLabel($0) } : nil
        return ContextChangesView(
            title: "Changes", changes: timeline, fileLabel: label,
            usage: { change in sessionsStarted(during: change, among: starts, claude: claude, codex: codex) },
            usageNoun: { $0 == 1 ? "session" : "sessions" }, now: max(to, Date()),
            info: "Each version of these instruction files the Hub has seen, with lines added and removed since the one before, plus Git commits that changed them when the project is scanned. Sessions count the agents' sessions in \(periodPhrase) that started while each version was current. Only line counts and fingerprints are kept, never the text.")
    }

    private func sessionsStarted(during change: ContextFileChange, among starts: [ActivitySession], claude: Set<String>, codex: Set<String>) -> Int {
        let end = change.validUntil ?? to
        return starts.filter { session in
            let reads = session.provider == .claude ? claude.contains(change.path) : (session.provider == .codex && codex.contains(change.path))
            return reads && session.createdAt >= change.date && session.createdAt < end
        }.count
    }

    private func fileLabel(_ path: String) -> String {
        if !row.isPersonal {
            let prefix = row.id.hasSuffix("/") ? row.id : row.id + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return SkillPresentation.homeRelative(path)
    }

    // Edits

    private var edits: some View {
        let shown = showAllEdits ? row.edits : Array(row.edits.prefix(5))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                SectionTitle(text: "Agent edits", icon: "pencil.line")
                Spacer()
                Text("Click to inspect the turn").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            }
            VStack(spacing: 1) {
                ForEach(shown) { edit in editRow(edit) }
            }
            if row.edits.count > 5 {
                Button(showAllEdits ? "Show fewer" : "Show \(row.edits.count - 5) more") { showAllEdits.toggle() }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
            }
        }
    }

    private func editRow(_ edit: InstructionReport.Edit) -> some View {
        let session = sessions[edit.sessionID]
        let parent = session?.parentSessionID.flatMap { sessions[$0] }
        let title = session.map { ActivityTitles.display($0.title, provider: $0.provider, projectPath: $0.projectPath, parentTitle: parent?.title) } ?? "Session"
        return Button { inspect(edit) } label: {
            HStack(spacing: 8) {
                Text(InstructionPresentation.timeLabel(edit.timestamp, now: to)).font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                    .lineLimit(1).frame(width: 74, alignment: .leading)
                AgentAvatar(name: edit.provider.rawValue.capitalized, size: 12)
                Text(edit.fileName).font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                Text(title).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: TurnStatusBadge.symbol(edit.turnStatus)).font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(TurnStatusBadge.color(edit.turnStatus)).help(edit.turnStatus.title)
            }
            .padding(.horizontal, 6).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contextMenu {
            Button("Inspect turn") { inspect(edit) }
            Button("Session details") { showSession(edit.sessionID) }
            Button("Show file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: edit.path)]) }
        }
        .accessibilityLabel("\(edit.fileName) edited by \(SkillReport.providerName(edit.provider)), \(InstructionPresentation.timeLabel(edit.timestamp, now: to)), \(title)")
        .accessibilityHint("Inspect this turn")
    }

    // Trend

    private var trend: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "Sessions over \(periodPhrase)", icon: "chart.bar")
            MiniBars(values: row.buckets.map { Double($0) }, tint: BridgeTheme.brand, emptyIndices: [], height: 36)
            if let first = bucketStarts.first {
                HStack {
                    Text(hourly ? first.formatted(.dateTime.hour()) : first.formatted(.dateTime.day().month(.abbreviated)))
                    Spacer()
                    Text(hourly ? "Now" : "Today")
                }
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sessions over \(periodPhrase): \(row.totalSessions)")
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Presentation

struct InstructionBanner: Identifiable {
    var id: String
    var tone: ActivityHighlight.Tone
    var title: String
    var detail: String
    var icon: String
}

enum InstructionPresentation {
    static func tokens(_ characters: Int) -> String { SkillReport.tokens(max(characters > 0 ? 1 : 0, characters / 4)) }

    static func kilobytes(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    /// "Same rules for both · AGENTS.md", "Claude: CLAUDE.md · Codex: AGENTS.md".
    static func summary(_ row: InstructionReport.ProjectRow, catalog: InstructionCatalog?) -> String {
        guard let instructions = row.instructions else { return "Not read yet" }
        func names(_ chain: InstructionChain, personal: Bool) -> String {
            let links = personal ? chain.links : chain.projectLinks.filter { catalog?.file($0.path)?.isPointer != true }
            let unique = links.reduce(into: [String]()) { list, link in
                let name = (link.path as NSString).lastPathComponent
                if !list.contains(name) { list.append(name) }
            }
            return unique.prefix(2).joined(separator: ", ") + (unique.count > 2 ? " +\(unique.count - 2)" : "")
        }
        if row.isPersonal {
            let claude = names(instructions.claude, personal: true), codex = names(instructions.codex, personal: true)
            switch (claude.isEmpty, codex.isEmpty) {
            case (false, false): return "Claude: \(claude) · Codex: \(codex)"
            case (false, true): return "Claude only: \(claude)"
            case (true, false): return "Codex only: ~/.codex/\(codex)"
            default: return "No personal rules"
            }
        }
        switch instructions.parity {
        case .same: return "Same rules for both · \(names(instructions.codex, personal: false).ifEmpty(names(instructions.claude, personal: false)))"
        case .overlap: return "Shared rules, plus more for one agent"
        case .different: return "Claude: \(names(instructions.claude, personal: false)) · Codex: \(names(instructions.codex, personal: false))"
        case .claudeOnly: return "Claude only · \(names(instructions.claude, personal: false))"
        case .codexOnly: return "Codex only · \(names(instructions.codex, personal: false))"
        case .none: return "No project rules"
        }
    }

    static func banners(_ row: InstructionReport.ProjectRow, catalog: InstructionCatalog) -> [InstructionBanner] {
        guard let instructions = row.instructions else { return [] }
        var banners: [InstructionBanner] = []
        if row.isPersonal {
            if instructions.parity == .codexOnly {
                banners.append(InstructionBanner(id: "personal", tone: .neutral, title: "Only Codex has your personal rules",
                    detail: "To give Claude Code the same, create ~/.claude/CLAUDE.md containing @~/.codex/AGENTS.md.", icon: "arrow.left.arrow.right"))
            } else if instructions.parity == .claudeOnly {
                banners.append(InstructionBanner(id: "personal", tone: .neutral, title: "Only Claude Code has your personal rules",
                    detail: "Codex reads ~/.codex/AGENTS.md. Copy your rules there to give it the same.", icon: "arrow.left.arrow.right"))
            }
            return banners
        }
        if row.olderClaudeSessions > 0 {
            banners.append(InstructionBanner(id: "older", tone: .warning, title: "\(row.olderClaudeSessions) Claude sessions worked without these rules",
                detail: "They ran a Claude Code version older than 2.1.299, which doesn't read AGENTS.md. Update Claude Code, or add a CLAUDE.md that says @AGENTS.md.", icon: "clock.arrow.circlepath"))
        }
        for (agent, count) in row.missingSessions.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let name = SkillReport.providerName(agent)
            banners.append(InstructionBanner(id: "missing-\(agent.rawValue)", tone: .warning, title: "\(name) worked here \(count)× without project rules",
                detail: agent == .codex ? "Codex reads AGENTS.md, not CLAUDE.md. Move the rules into AGENTS.md and make CLAUDE.md say @AGENTS.md."
                    : "Claude Code had no project rules in these sessions. A CLAUDE.md that says @AGENTS.md gives it the same rules as Codex.",
                icon: "doc.badge.ellipsis"))
        }
        if instructions.codex.truncatedBytes > 0 {
            banners.append(InstructionBanner(id: "cut", tone: .warning, title: "Codex never reads the last \(kilobytes(instructions.codex.truncatedBytes))",
                detail: "Codex stops at 32 KB of project instructions by default. Move detail into a skill or a document the file links to.", icon: "scissors"))
        }
        switch instructions.parity {
        case .same:
            let fallback = instructions.claude.links.contains { $0.reason == .fallback }
            let pointer = instructions.claude.projectLinks.contains { catalog.file($0.path)?.isPointer == true }
            banners.append(InstructionBanner(id: "parity", tone: .positive, title: "Both agents read the same rules",
                detail: fallback ? "Claude Code reads AGENTS.md here because the project has no CLAUDE.md."
                    : (pointer ? "CLAUDE.md points Claude Code at AGENTS.md." : "Claude Code and Codex read the same files."),
                icon: "checkmark.seal"))
        case .overlap:
            banners.append(InstructionBanner(id: "parity", tone: .notable, title: "One agent reads extra rules",
                detail: "They share some files, but not all. Check the lists below for files only one agent reads.", icon: "square.on.square"))
        case .different:
            banners.append(InstructionBanner(id: "parity", tone: .warning, title: "Claude and Codex follow different rules",
                detail: "Claude Code reads CLAUDE.md and Codex reads AGENTS.md, and they say different things. Move the rules into AGENTS.md and make CLAUDE.md say @AGENTS.md.",
                icon: "arrow.triangle.branch"))
        case .claudeOnly where (row.sessions[.codex] ?? 0) == 0 && row.missingSessions.isEmpty:
            banners.append(InstructionBanner(id: "parity", tone: .neutral, title: "Only Claude Code has project rules here",
                detail: "Codex reads AGENTS.md. If Codex will work here, move the rules into AGENTS.md and make CLAUDE.md say @AGENTS.md.", icon: "info.circle"))
        case .codexOnly where row.missingSessions.isEmpty && row.olderClaudeSessions == 0:
            banners.append(InstructionBanner(id: "parity", tone: .neutral, title: "Only Codex has project rules here",
                detail: "Add a CLAUDE.md that says @AGENTS.md to give Claude Code the same rules.", icon: "info.circle"))
        case .none:
            banners.append(InstructionBanner(id: "parity", tone: .neutral, title: "No project rules",
                detail: "An AGENTS.md at the project root gives both agents the same rules: Codex reads it, and Claude Code reads it when there's no CLAUDE.md.",
                icon: "doc.badge.plus"))
        default: break
        }
        return banners
    }

    static func emptyChain(_ agent: AgentName, personal: Bool) -> String {
        if personal { return agent == .claude ? "No ~/.claude/CLAUDE.md" : "No ~/.codex/AGENTS.md" }
        return agent == .claude ? "No CLAUDE.md, AGENTS.md or memory for this folder" : "No AGENTS.md from the repository root to this folder"
    }

    static func symbol(_ link: InstructionLink) -> String {
        switch link.reason {
        case .personal: return "person.crop.circle"
        case .project: return "doc.text"
        case .local: return "lock.doc"
        case .rule: return "list.bullet.rectangle"
        case .imported: return "arrow.turn.down.right"
        case .fallback: return "doc.text"
        case .memory: return "brain"
        }
    }

    static func reason(_ link: InstructionLink, catalog: InstructionCatalog) -> String {
        switch link.reason {
        case .personal: return "Yours"
        case .project: return "Project"
        case .local: return "Private"
        case .rule: return "Rule"
        case .imported: return "Imported by \(link.importedBy.map { ($0 as NSString).lastPathComponent } ?? "a file")"
        case .fallback: return "Instead of CLAUDE.md"
        case .memory: return "Memory"
        }
    }

    /// Paths relative to the project where they sit inside it; "~/…" otherwise.
    static func fileName(_ link: InstructionLink, project: String?) -> String {
        if link.reason == .memory { return "MEMORY.md" }
        if let project {
            let prefix = project.hasSuffix("/") ? project : project + "/"
            if link.path.hasPrefix(prefix) { return String(link.path.dropFirst(prefix.count)) }
        }
        return SkillPresentation.homeRelative(link.path)
    }

    /// "14:05" today, "5 Nov 22:46" before.
    static func timeLabel(_ date: Date, now: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        return Calendar.current.isDate(date, inSameDayAs: now) ? time : "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
    }
}
