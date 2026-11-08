import BridgeCore
import SwiftUI

/// Keeps the goal's turn list between 30-second clock ticks and redraws.
final class GoalTurnsCache {
    private struct Key: Equatable {
        var revision: UInt64
        var from: Date
        var to: Date
        var sessionIDs: [String]
    }
    private var key: Key?
    private var rows: [GoalTurnList.Row] = []

    func rows(sessions: [ActivitySession], from: Date, to: Date, now: Date, revision: UInt64) -> [GoalTurnList.Row] {
        let incoming = Key(revision: revision, from: from, to: to, sessionIDs: sessions.map(\.id).sorted())
        if incoming != key {
            rows = GoalTurnList.rows(sessions: sessions, from: from, to: to, now: now)
            key = incoming
        }
        return rows
    }
}

/// Every recorded turn in the goal's range, newest first, one line each.
/// Clicking a row opens the same drawer as a swimlane block.
struct GoalTurnsSection: View {
    var sessions: [ActivitySession]
    var laneTitles: [String: String]
    var assignments: [String: AgentPersonaCatalog.Assignment]
    var overview: ActivityOverview
    var from: Date
    var to: Date
    var now: Date
    var revision: UInt64

    @State private var filter: GoalTurnList.Filter = .all
    @State private var limit = Self.pageSize
    @State private var cache = GoalTurnsCache()
    @Environment(\.inspectedTurn) private var inspected

    private static let pageSize = 12

    var body: some View {
        let all = cache.rows(sessions: sessions, from: from, to: to, now: now, revision: revision)
        let shown = filter == .all ? all : all.filter { GoalTurnList.matches($0, filter) }
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { title(all.count); Spacer(minLength: 12); filters(all) }
                VStack(alignment: .leading, spacing: 8) { title(all.count); filters(all) }
            }
            if shown.isEmpty {
                Text(all.isEmpty ? "No dated turns in this range." : "No turns match this filter.")
                    .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                LazyVStack(spacing: 1) {
                    ForEach(shown.prefix(limit)) { row in turnRow(row) }
                }
                .padding(4)
                .bridgeWell(cornerRadius: 10)
                if shown.count > limit {
                    HStack(spacing: 10) {
                        Button("Show \(min(25, shown.count - limit)) more") { limit += 25 }
                            .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
                        Text("Showing \(limit) of \(shown.count)").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .onChange(of: filter) { _ in limit = Self.pageSize }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.goal.turns")
    }

    private func title(_ count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SectionTitle(text: "Turns", icon: "list.bullet.rectangle")
            Text("\(count) in this range").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
        }
        .fixedSize()
    }

    private func filters(_ rows: [GoalTurnList.Row]) -> some View {
        HStack(spacing: 4) {
            ForEach(GoalTurnList.Filter.allCases) { option in
                let count = option == .all ? rows.count : rows.filter { GoalTurnList.matches($0, option) }.count
                let selected = filter == option
                Button { filter = option } label: {
                    HStack(spacing: 4) {
                        Text(option.rawValue)
                        if option != .all { Text("\(count)").monospacedDigit().foregroundStyle(selected ? BridgeTheme.brand : BridgeTheme.textTertiary) }
                    }
                    .font(BridgeFont.captionMedium)
                    .foregroundStyle(selected ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(selected ? BridgeTheme.brand.opacity(0.14) : Color.white.opacity(0.04), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(option != .all && count == 0 && !selected)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .help(help(option))
            }
        }
        .fixedSize()
    }

    private func help(_ option: GoalTurnList.Filter) -> String {
        switch option {
        case .all: return "Every dated turn in this range"
        case .problems: return "Turns that failed or were interrupted. Tool errors inside a turn show in its drawer."
        case .tools: return "Turns with recorded tool calls"
        case .long: return "Turns that ran ten minutes or longer, including waits"
        }
    }

    private func turnRow(_ row: GoalTurnList.Row) -> some View {
        let selected = inspected?.sessionID == row.sessionID && inspected?.turnID == row.turnID
        let agent = laneTitles[row.sessionID] ?? "Agent"
        return Button {
            Task { @MainActor in ActivityReportsController.shared.inspectTurn(overview: overview, sessionID: row.sessionID, turnID: row.turnID, snapshotRevision: revision) }
        } label: {
            HStack(spacing: 10) {
                Text(timeLabel(row.start)).font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                    .frame(width: 70, alignment: .leading)
                AgentPortrait(persona: assignments[row.sessionID]?.persona, provider: row.provider, size: 18,
                              recent: row.status == .inProgress, showBadge: false)
                Text(agent).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
                if let category = row.category {
                    Label(category, systemImage: BridgeTheme.categorySymbol(category))
                        .labelStyle(CompactLabelStyle()).font(BridgeFont.caption)
                        .foregroundStyle(BridgeTheme.category(category)).lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if let steps = row.stepCount { Text("\(steps) \(steps == 1 ? "step" : "steps")") }
                    if let tools = row.toolCount, tools > 0 { Text("\(tools) \(tools == 1 ? "tool" : "tools")") }
                    Text(row.duration.map { ActivityFormat.duration($0) } ?? (row.status == .inProgress ? "open" : "—"))
                        .frame(minWidth: 34, alignment: .trailing)
                }
                .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary).fixedSize()
                Image(systemName: TurnStatusBadge.symbol(row.status))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(TurnStatusBadge.color(row.status))
                    .frame(width: 16)
                    .help(row.status.title)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(selected ? BridgeTheme.brand.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected ? BridgeTheme.brand.opacity(0.45) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityLabel("\(agent), \(timeLabel(row.start)), \(row.status.title)\(row.duration.map { ", " + ActivityFormat.duration($0) } ?? "")")
        .accessibilityHint("Inspect this turn")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func timeLabel(_ date: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}
