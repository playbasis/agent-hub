import BridgeCore
import SwiftUI

/// WorkspaceOps-style team roster: a stat strip, filter pills with counts, a
/// sort menu, work cards and compact evidence rows for other saved sessions.
struct TeamRosterView: View {
    var roster: Roster
    var now: Date
    var selectedID: String?
    var select: (String) -> Void
    /// Observed model steps per chart bucket, by session.
    var trends: [String: PreparedReportScope.Trend] = [:]
    var trendUnit = "day"

    @AppStorage("teamRoster.filter") private var filter = "all"
    @AppStorage("teamRoster.sort") private var sort = Sort.active.rawValue
    @AppStorage("bridge.showPersonas") private var showPersonas = true
    @State private var showOtherSessions = false
    @State private var otherSessionLimit = 24

    enum Sort: String, CaseIterable, Identifiable {
        case active = "Recorded time", recent = "Most recent", role = "Role order"
        var id: String { rawValue }
        /// Display names; raw values stay stable for saved preferences.
        var title: String {
            switch self { case .active: return "Most active"; case .recent: return "Most recent"; case .role: return "By role" }
        }
    }

    struct Member: Identifiable {
        var session: ActivitySession
        var assignment: AgentPersonaCatalog.Assignment?
        var accounting: ActivityAccounting.Report
        var recordedSeconds: Double? { accounting.sessionWorkSeconds[session.id] }
        var turns: Int { accounting.totals.nativeRecords }
        var tokens: Int? { accounting.totals.tokensKnown }
        var lastActivity: Date?
        var recent: Bool
        var mix: [ActivityAnalytics.Share]
        var models: [String]
        var efforts: [String]
        var evidence: AgentRosterEvidence
        var role: AgentRole?
        var id: String { session.id }
        var displayTitle: String { AgentRosterEvidence.displayTitle(session) }
        var nativeIdentity: String { ActivityTitles.providerName(session.provider) + " · " + (session.nativeID.isEmpty ? session.id : session.nativeID) }
        var hasPeriodWork: Bool { evidence == .recorded }
    }

    /// Everything the page shows, built once per snapshot and filter change by
    /// the workspace's report cache rather than on every redraw.
    struct Roster {
        var members: [Member]
        var activeSeconds: Double?
        var models: Int
        var accounting: ActivityAccounting.Report

        static func build(sessions: [ActivitySession], overview: ActivityOverview,
                          assignments: [String: AgentPersonaCatalog.Assignment], now: Date, after: Date?) -> Roster {
            let report = ActivityAccounting.build(overview: overview, sessionIDs: Set(sessions.map(\.id)), from: after, to: now)
            return build(sessions: sessions, overview: overview, assignments: assignments, now: now, accounting: report, bySession: report.bySession())
        }

        static func build(sessions: [ActivitySession], overview: ActivityOverview,
                          assignments: [String: AgentPersonaCatalog.Assignment], now: Date,
                          accounting report: ActivityAccounting.Report, bySession: [String: ActivityAccounting.Report]) -> Roster {
            // One full-snapshot ownership index, not one history walk per card.
            // A project/search filter must not turn inherited records into work.
            let records = TurnInspectionRecords(overview.sessions)
            let empty = report.projected(sessionIDs: [])
            var seen = Set<String>()
            let members = sessions.filter { seen.insert($0.id).inserted }.map { input -> Member in
                let session = records.byID[input.id] ?? input
                let own = bySession[session.id] ?? empty
                let lastRecorded = ActivityReportPresentation.lastActivity(own)
                return Member(
                    session: session,
                    assignment: assignments[session.id],
                    accounting: own,
                    lastActivity: lastRecorded,
                    recent: ActivityPresentationPolicy.isRecent(lastRecorded, now: now),
                    mix: ActivityReportPresentation.mix(own),
                    models: ActivityReportPresentation.models(own),
                    efforts: ActivityReportPresentation.efforts(own),
                    evidence: AgentRosterEvidence.read(sessionID: session.id, report: own, records: records),
                    role: AgentRosterEvidence.role(own)
                )
            }
            return Roster(members: members,
                          activeSeconds: report.totals.activeSeconds,
                          models: report.totals.modelIdentities, accounting: report)
        }
    }

    var body: some View {
        let all = roster.members
        let visible = sorted(all.filter(matches))
        let recorded = visible.filter(\.hasPeriodWork)
        let other = visible.filter { !$0.hasPeriodWork }
        VStack(alignment: .leading, spacing: 16) {
            StatStrip(items: [
                .init(value: "\(all.count)", label: "saved sessions", icon: "person.2",
                      help: "Sessions matching the provider, project and search, including side chats and sessions without work in this period"),
                .init(value: "\(all.filter(\.recent).count)", label: "recent activity", icon: "waveform.path",
                      color: all.contains(where: \.recent) ? BridgeTheme.success : BridgeTheme.textPrimary,
                      help: "Sessions with dated canonical evidence in the last 15 minutes, not a live process check"),
                .init(value: "\(all.filter { $0.session.isChild }.count)", label: "sub-agents", icon: "arrow.turn.down.right",
                      help: "Agents started by another agent to handle part of the work"),
                .init(value: roster.models > 0 ? "\(roster.models)" : "—", label: roster.models == 1 ? "model" : "models", icon: "cpu",
                      help: "Distinct provider/model pairs in observed canonical steps for this period"),
                .init(value: ActivityFormat.duration(roster.activeSeconds), label: "active time", icon: "clock",
                      help: "Time with at least one agent working; overlapping agents count once"),
            ])
            .padding(.vertical, 12)
            .bridgeCard(padding: 0)

            Text("\(all.filter(\.hasPeriodWork).count) with recorded work in this period · \(all.filter { !$0.hasPeriodWork }.count) other saved sessions")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    filters(all)
                    Spacer(minLength: 8)
                    sortControl
                }
                VStack(alignment: .leading, spacing: 10) {
                    ScrollView(.horizontal, showsIndicators: false) { filters(all) }
                    HStack { Spacer(); sortControl }
                }
            }

            if visible.isEmpty {
                HubEmptyState(icon: "person.2", title: "No agents match this filter",
                              message: "Try another role or a longer period.")
            } else {
                if !recorded.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], spacing: 12) {
                        ForEach(recorded) { member in
                            Button { select(member.id) } label: {
                                AgentCard(member: member, now: now, selected: selectedID == member.id,
                                          trend: trends[member.id], trendUnit: trendUnit)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selectedID == member.id ? [.isSelected] : [])
                            .accessibilityHint("Open session details")
                            .accessibilityIdentifier("team-roster-session-\(member.id)")
                        }
                    }
                }
                if !other.isEmpty {
                    if recorded.isEmpty {
                        otherSessions(other)
                    } else {
                        DisclosureGroup(isExpanded: $showOtherSessions) {
                            otherSessions(other).padding(.top, 8)
                        } label: {
                            Text("\(other.count) other saved \(other.count == 1 ? "session" : "sessions")")
                                .font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textSecondary)
                        }
                    }
                }
            }
            Text(showPersonas
                 ? "Roles reflect recorded tools in this period. Portraits are decorative and can be turned off in Settings."
                 : "Roles reflect recorded tools in this period. A missing role means tool categories are unavailable.")
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            if let error = PersonaDirectory.persistenceError {
                Text("\(error) Portraits are stable for this run, but may change after restart.")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            AcceptanceProbe.handleSafe(note, scope: "agents", state: {
                ["filter": effectiveFilter, "sort": sort]
            }, exercise: {
                guard AcceptanceProbe.defaults !== UserDefaults.standard, !roster.members.isEmpty else { return false }
                // AppStorage is hosted in the per-process acceptance suite.
                // No model settings, native agent or repository action occurs.
                filter = roster.members.compactMap(\.role).first?.rawValue ?? "all"
                sort = Sort.recent.rawValue
                return true
            })
        }
    }

    private var effectiveFilter: String {
        (["all", "recent", "other"] + AgentRole.allCases.map(\.rawValue)).contains(filter) ? filter : "all"
    }

    private func filters(_ all: [Member]) -> some View {
        HStack(spacing: 8) {
            pill("all", "All", count: all.count, icon: nil)
            pill("recent", "Recent", count: all.filter(\.recent).count, icon: "waveform.path")
            pill("other", "Other saved", count: all.filter { !$0.hasPeriodWork }.count, icon: "tray")
            ForEach(AgentRole.allCases, id: \.self) { role in
                let count = all.filter { $0.role == role }.count
                if count > 0 || effectiveFilter == role.rawValue {
                    pill(role.rawValue, role.title, count: count, icon: role.symbol)
                }
            }
        }.fixedSize(horizontal: true, vertical: false)
    }

    private var sortControl: some View {
        let current = Sort(rawValue: sort) ?? .active
        return Menu {
            ForEach(Sort.allCases) { option in
                Button { sort = option.rawValue } label: {
                    if option == current { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10, weight: .semibold))
                Text(current.title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(BridgeTheme.textTertiary)
            }
            .font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textSecondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 9).frame(height: 26)
        .bridgeWell(cornerRadius: 7)
        .help("Sort agents")
        .accessibilityLabel("Sort agents, \(current.title)")
    }

    private func matches(_ member: Member) -> Bool {
        switch effectiveFilter {
        case "all": return true
        case "recent": return member.recent
        case "other": return !member.hasPeriodWork
        default: return member.role?.rawValue == filter
        }
    }

    private func sorted(_ list: [Member]) -> [Member] {
        switch Sort(rawValue: sort) ?? .active {
        case .active:
            return list.sorted { ($0.recordedSeconds ?? -1, $0.turns, $0.id) > ($1.recordedSeconds ?? -1, $1.turns, $1.id) }
        case .recent:
            return list.sorted { ($0.lastActivity ?? .distantPast, $0.id) > ($1.lastActivity ?? .distantPast, $1.id) }
        case .role:
            let order = Dictionary(uniqueKeysWithValues: AgentRole.allCases.enumerated().map { ($1, $0) })
            return list.sorted {
                let left = $0.role.flatMap { order[$0] } ?? 9, right = $1.role.flatMap { order[$0] } ?? 9
                if left != right { return left < right }
                let titleOrder = $0.session.title.localizedStandardCompare($1.session.title)
                return titleOrder == .orderedSame ? $0.id < $1.id : titleOrder == .orderedAscending
            }
        }
    }

    private func otherSessions(_ members: [Member]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No separately dated work in this period")
                .font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
            Text("Side chats and other discovered sessions stay available here. Their saved-history state is shown below; missing work is not treated as zero or idle.")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVStack(spacing: 8) {
                ForEach(Array(members.prefix(otherSessionLimit))) { member in
                    Button { select(member.id) } label: {
                        AgentEvidenceRow(member: member, now: now, selected: selectedID == member.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedID == member.id ? [.isSelected] : [])
                    .accessibilityHint("Open saved session details")
                    .accessibilityIdentifier("team-roster-session-\(member.id)")
                }
            }
            if members.count > otherSessionLimit {
                Button("Show \(min(24, members.count - otherSessionLimit)) more saved sessions") { otherSessionLimit += 24 }
                    .buttonStyle(BridgeLinkButtonStyle())
            }
        }
        .padding(12).bridgeCard(padding: 0)
    }

    private func pill(_ key: String, _ title: String, count: Int, icon: String?) -> some View {
        let selected = effectiveFilter == key
        return Button { withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.15)) { filter = key } } label: {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
                Text(title).font(BridgeFont.secondaryMedium)
                Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(selected ? BridgeTheme.ink.opacity(0.15) : Color.white.opacity(0.08)))
            }
            .foregroundStyle(selected ? BridgeTheme.ink : BridgeTheme.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color.white.opacity(0.92) : Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : BridgeTheme.surfaceBorder, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) agent\(count == 1 ? "" : "s")")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct AgentCard: View {
    var member: TeamRosterView.Member
    var now: Date
    var selected: Bool
    var trend: PreparedReportScope.Trend? = nil
    var trendUnit = "day"
    @AppStorage("bridge.showPersonas") private var showPersonas = true

    private var session: ActivitySession { member.session }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 11) {
                AgentPortrait(persona: member.assignment?.persona, provider: session.provider, size: 40, recent: member.recent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ActivityFormat.headline(member.displayTitle, limit: 80))
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                        .help(member.displayTitle)
                    // The provider's own session ID stays one hover away;
                    // the card names the provider and when it started.
                    Text("\(ActivityTitles.providerName(session.provider)) · started \(ActivityFormat.relative(session.createdAt, now: now))")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                        .lineLimit(1).help(member.nativeIdentity)
                    if let role = member.role {
                        HStack(spacing: 5) {
                            Image(systemName: role.symbol).font(.system(size: 9, weight: .semibold))
                            Text(showPersonas ? member.assignment?.persona.map { "\($0.firstName) · \(role.title)" } ?? role.title : role.title)
                        }
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                        .help("\(role.title): \(role.explanation) Based on recorded tools in this period.")
                    }
                }
                Spacer(minLength: 6)
                status
            }

            if !member.models.isEmpty || !member.efforts.isEmpty || session.isChild || !session.historyComplete {
                HStack(spacing: 5) {
                    if let model = member.models.first {
                        Tag(text: ModelNaming.display(model), color: BridgeTheme.color(for: session.provider))
                            .lineLimit(1).help(member.models.joined(separator: ", "))
                        if member.models.count > 1 { Tag(text: "+\(member.models.count - 1)").help(member.models.map(ModelNaming.display).joined(separator: ", ")) }
                    }
                    if let effort = member.efforts.first {
                        Tag(text: member.efforts.count == 1 ? ModelNaming.effort(effort) : "\(member.efforts.count) effort levels")
                            .help("Reasoning effort: " + member.efforts.map(ModelNaming.effort).joined(separator: ", "))
                    }
                    if session.isChild { Tag(text: "Sub-agent") }
                    if !session.historyComplete {
                        Image(systemName: "clock.badge.questionmark").font(.system(size: 10)).foregroundStyle(BridgeTheme.textTertiary)
                            .help("Only part of this session's history was available, so its numbers are minimums")
                    }
                }
                .padding(.top, 12)
            }

            workMix.padding(.top, 12)

            Rectangle().fill(BridgeTheme.separator).frame(height: 1).padding(.top, 10)

            HStack(alignment: .bottom, spacing: 0) {
                stat(ActivityReportPresentation.steps(member.accounting), "model steps")
                stat(ActivityFormat.duration(member.recordedSeconds), "active")
                stat(ActivityReportPresentation.tokens(member.accounting), "tokens")
                if let trend, trend.values.contains(where: { $0 != nil }) {
                    // When in the period this agent worked; brightest is now.
                    MiniBars(values: trend.values, tint: BridgeTheme.color(for: session.provider), emptyIndices: trend.empty, height: 26)
                        .frame(width: 84)
                        .help("Model steps per \(trendUnit) across the period")
                        .accessibilityLabel("Model steps per \(trendUnit)")
                }
            }
            .padding(.top, 10)

            HStack(spacing: 5) {
                Image(systemName: "folder").font(.system(size: 9))
                Text(ActivityFormat.project(session.projectPath)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(member.turns.formatted()) \(member.turns == 1 ? "request" : "requests")")
                    .help("Saved requests (native turns) that support this period's figures")
            }
            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            .padding(.top, 10)
            .help(session.projectPath ?? "")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.white.opacity(0.08) : BridgeTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? BridgeTheme.brand.opacity(0.6) : BridgeTheme.surfaceBorder, lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        if member.recent {
            HStack(spacing: 4) {
                Circle().fill(BridgeTheme.success).frame(width: 6, height: 6)
                Text("Recent").font(BridgeFont.captionMedium)
            }
            .foregroundStyle(BridgeTheme.success)
            .help("Dated canonical evidence in the last 15 minutes; not a live process check")
        } else {
            Text(member.lastActivity.map { ActivityFormat.relative($0, now: now) } ?? "No dated activity")
                .font(BridgeFont.caption.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                .lineLimit(2)
                .help(ActivityReportPresentation.recordedActivityHelp(member.lastActivity))
        }
    }

    @ViewBuilder private var workMix: some View {
        if member.mix.isEmpty {
            Text(member.accounting.totals.unallocatedNativeCounters.toolCalls != nil ? "Tool timing unavailable" : "Tool categories unavailable")
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
        } else {
            WorkMixBar(shares: member.mix, maxLegend: 2, compact: true)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(BridgeTheme.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A compact evidence row replaces the empty model/tool/stat slots of a card.
/// Every discovered native session remains selectable, even without receipts.
private struct AgentEvidenceRow: View {
    var member: TeamRosterView.Member
    var now: Date
    var selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgentPortrait(persona: member.assignment?.persona, provider: member.session.provider, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ActivityFormat.headline(member.displayTitle, limit: 100))
                        .font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                        .lineLimit(2).help(member.displayTitle)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(BridgeTheme.textTertiary).accessibilityHidden(true)
                }
                Text("\(ActivityTitles.providerName(member.session.provider)) · started \(ActivityFormat.relative(member.session.createdAt, now: now))" + (member.session.isChild ? " · Sub-agent" : ""))
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                    .lineLimit(1).help(member.nativeIdentity)
                Text(member.evidence.title).font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textSecondary)
                Text(member.evidence.explanation)
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let project = member.session.projectPath {
                    Label(ActivityFormat.project(project), systemImage: "folder")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                        .lineLimit(1).truncationMode(.middle).help(project)
                }
            }
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected ? BridgeTheme.control : BridgeTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(selected ? BridgeTheme.brand.opacity(0.6) : BridgeTheme.surfaceBorder, lineWidth: selected ? 1.5 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
