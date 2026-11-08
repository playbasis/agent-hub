import AppKit
import BridgeCore
import SwiftUI

/// "+60,302 −6,716" in Git's colours.
struct LinesChangedLabel: View {
    var lines: ShippedCodeReport.Lines
    var compact = false
    var font: Font = BridgeFont.numeral

    var body: some View {
        HStack(spacing: 5) {
            Text("+" + format(lines.additions)).foregroundStyle(BridgeTheme.success)
            Text("−" + format(lines.deletions)).foregroundStyle(BridgeTheme.danger)
        }
        .font(font.monospacedDigit())
        .lineLimit(1)
        .help("\(lines.additions.formatted()) lines added, \(lines.deletions.formatted()) removed")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lines.additions.formatted()) lines added, \(lines.deletions.formatted()) removed")
    }

    private func format(_ value: Int) -> String { compact ? ActivityFormat.compact(value) : value.formatted() }
}

enum ShippedPresentation {
    static func scanLine(_ totals: ShippedCodeReport.Totals, now: Date) -> String {
        guard let newest = totals.newestScan else { return "Not scanned yet" }
        return "Scanned \(ActivityFormat.relative(newest, now: now))"
    }

    static func tokensPerLine(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "≈" + ActivityFormat.compact(Int(value.rounded()))
    }

    static func linkSymbol(_ link: ShippedCodeReport.Link) -> String {
        switch link {
        case .coAuthored: return "person.2.fill"
        case .sameFiles: return "doc.on.doc"
        case .duringSession: return "clock"
        }
    }

    static func linkHelp(_ commit: ShippedCodeReport.Commit) -> String {
        guard let link = commit.link else { return "Not linked to an agent session in view" }
        let count = commit.sessionIDs.count
        switch link {
        case .coAuthored:
            let agents = commit.agents.map { SkillReport.providerName($0) }.joined(separator: " and ")
            return "Names \(agents) as a co-author" + (count > 0 ? " · \(count) \(count == 1 ? "session" : "sessions") ran then" : "")
        case .sameFiles: return "Changes files \(count == 1 ? "a session" : "\(count) sessions") edited while running"
        case .duringSession: return "Landed in this repository while \(count == 1 ? "a session was" : "\(count) sessions were") running, or within two hours after"
        }
    }

    /// The headline metric items for the Projects page.
    static func metrics(_ result: ShippedCodeReport.Result, periodPhrase: String) -> [MetricItem] {
        let totals = result.totals
        let coAuthors = [AgentName.claude, .codex].compactMap { agent -> String? in
            guard let count = totals.coAuthoredByAgent[agent], count > 0 else { return nil }
            return "\(SkillReport.providerName(agent)) \(count)"
        }.joined(separator: " · ")
        let generated = totals.generatedLines.total > 0 && totals.lines.total > 0
            ? Int((Double(totals.generatedLines.total) / Double(totals.lines.total) * 100).rounded()) : 0
        return [
            MetricItem(title: "Lines changed", icon: "plus.forwardslash.minus",
                       value: "+\(ActivityFormat.compact(totals.lines.additions)) / −\(ActivityFormat.compact(totals.lines.deletions))",
                       footnote: "\(totals.commits.formatted()) \(totals.commits == 1 ? "commit" : "commits") · \(totals.filesChanged.formatted()) files" + (generated >= 10 ? " · \(generated)% lock files" : ""),
                       info: "Lines added and removed in commits from the last scan, in \(periodPhrase): \(totals.lines.additions.formatted()) added and \(totals.lines.deletions.formatted()) removed. Lock and generated files are included" + (totals.generatedLines.total > 0 ? " (\(ShippedCodeReport.linesLabel(totals.generatedLines)))." : ".")),
            MetricItem(title: "Linked to agents", icon: "link",
                       value: totals.commits > 0 ? "\(totals.linkedCommits) of \(totals.commits)" : "—",
                       footnote: totals.linkedLines.total > 0 ? ShippedCodeReport.linesLabel(totals.linkedLines) + " lines" : "No linked commits",
                       info: result.notes.dropFirst().first ?? ""),
            MetricItem(title: "Tokens per line", icon: "circle.hexagongrid",
                       value: ShippedPresentation.tokensPerLine(totals.tokensPerLine),
                       footnote: totals.outputTokensPerLine.map { "≈\(ActivityFormat.compact(Int($0.rounded()))) written a line" } ?? "Needs linked commits",
                       info: "Known tokens of agent sessions in scanned repositories (\(ActivityFormat.compact(totals.tokens))) divided by the lines in commits linked to them: a rough cost of change, not a quality measure. Most of it is context re-sent from cache on every step. Written tokens (\(ActivityFormat.compact(totals.outputTokens))) are only what the agents produced" + (totals.tokensPerCommit.map { "; about \(ActivityFormat.compact(Int($0.rounded()))) tokens a linked commit." } ?? ".")),
            MetricItem(title: "Co-authored", icon: "person.2",
                       value: totals.coAuthoredCommits.formatted(),
                       footnote: coAuthors.isEmpty ? "No agent co-author trailers" : coAuthors,
                       info: "Commits whose message names Claude or Codex in a Co-authored-by trailer, as Claude Code adds by default. The strongest link to an agent."),
            MetricItem(title: "No linked commit", icon: "tray",
                       value: totals.sessions > 0 ? "\(totals.sessionsWithoutCommits) of \(totals.sessions)" : "—",
                       footnote: totals.tokensWithoutCommits > 0 ? "≈\(ActivityFormat.compact(totals.tokensWithoutCommits)) tokens" : "Sessions in scanned repos",
                       info: "Agent sessions in scanned repositories with no commit linked to them in this period. Research, reviews, planning and uncommitted work all land here; it isn't wasted work by definition."),
        ]
    }
}

/// One commit: hash, subject, lines, and how it's tied to agent sessions.
struct ShippedCommitRow: View {
    var commit: ShippedCodeReport.Commit
    var sessions: [String: ActivitySession]
    var now: Date
    var showSession: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(commit.commit.id.prefix(7))).font(BridgeFont.mono).foregroundStyle(BridgeTheme.textTertiary)
                .textSelection(.enabled)
            Text(commit.commit.subject).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                .help(commit.commit.subject)
            Spacer(minLength: 6)
            if let link = commit.link {
                HStack(spacing: 3) {
                    Image(systemName: ShippedPresentation.linkSymbol(link)).font(.system(size: 9, weight: .semibold))
                    ForEach(providers, id: \.self) { agent in AgentAvatar(name: agent.rawValue.capitalized, size: 12) }
                }
                .foregroundStyle(link == .duringSession ? BridgeTheme.textTertiary : BridgeTheme.brand)
                .help(ShippedPresentation.linkHelp(commit))
                .onTapGesture { if let first = commit.sessionIDs.first { showSession(first) } }
            }
            if commit.commit.additions != nil {
                LinesChangedLabel(lines: ShippedCodeReport.Lines(additions: commit.commit.additions ?? 0, deletions: commit.commit.deletions ?? 0),
                                  compact: true, font: BridgeFont.micro)
                    .frame(minWidth: 78, alignment: .trailing)
            }
            Text(ActivityFormat.relative(commit.commit.timestamp, now: now)).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// Agents of the linked sessions, else the named co-authors.
    private var providers: [AgentName] {
        let linked = Set(commit.sessionIDs.compactMap { sessions[$0]?.provider })
        let values = linked.isEmpty ? Set(commit.agents) : linked
        return values.sorted { $0.rawValue < $1.rawValue }
    }
}

/// A one-line summary of shipped code on the Overview.
struct ShippedOverviewCard: View {
    var result: ShippedCodeReport.Result
    var periodPhrase: String
    var now: Date
    var scanning: Bool
    var scan: () -> Void
    var openProjects: () -> Void
    /// Start of the period, for the commit timeline; nil hides it.
    var from: Date? = nil

    var body: some View {
        let totals = result.totals
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 13, weight: .semibold)).foregroundStyle(BridgeTheme.brand)
                .frame(width: 30, height: 30).background(BridgeTheme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            if result.hasScan {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Shipped").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                        if totals.commits > 0 {
                            LinesChangedLabel(lines: totals.lines, font: .system(size: 13, weight: .semibold))
                        } else {
                            Text("no commits found").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textTertiary)
                        }
                    }
                    Text("\(totals.commits.formatted()) \(totals.commits == 1 ? "commit" : "commits") in \(periodPhrase) · \(totals.linkedCommits) linked to agent sessions · \(ShippedPresentation.scanLine(totals, now: now).lowercased())")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let from, from < now, !result.commits.isEmpty {
                    CommitTimeline(commits: result.commits, from: from, to: now)
                        .frame(minWidth: 120, idealWidth: 240, maxWidth: 280).frame(height: 28)
                        .layoutPriority(-1)
                }
                fact(ShippedPresentation.tokensPerLine(totals.tokensPerLine), "tokens a line")
                fact(totals.sessions > 0 ? "\(totals.sessionsWithoutCommits)" : "—", "sessions, no commit")
                Button("Details", action: openProjects).buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("See what your agents shipped").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                    Text("Scan your projects' Git history to link commits and lines changed to the sessions that worked on them. Read-only.")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(2)
                }
                Spacer(minLength: 8)
                Button(scanning ? "Scanning…" : "Scan projects", action: scan)
                    .buttonStyle(BridgeSecondaryButtonStyle(compact: true)).disabled(scanning)
            }
        }
        .bridgeCard(padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.overview.shipped")
    }

    private func fact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value).font(BridgeFont.numeral).foregroundStyle(BridgeTheme.textPrimary)
            Text(label).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
        }
    }
}

/// Commits across the period as ticks on a time line: taller for bigger
/// changes (log scale), cyan when an agent is named or edited the same files,
/// grey when the commit only landed while a session ran or isn't linked.
struct CommitTimeline: View {
    var commits: [ShippedCodeReport.Commit]
    var from: Date
    var to: Date

    var body: some View {
        Canvas { context, size in
            let span = to.timeIntervalSince(from)
            guard span > 0, size.width > 4, size.height > 4 else { return }
            context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(BridgeTheme.separator))
            let peak = log1p(Double(commits.map(\.lineCount).max() ?? 1))
            for commit in commits.sorted(by: { $0.lineCount < $1.lineCount }) {
                let offset = commit.commit.timestamp.timeIntervalSince(from) / span
                guard offset.isFinite, offset >= 0, offset <= 1 else { continue }
                let x = min(size.width - 2, max(0, CGFloat(offset) * size.width - 1))
                let scale = peak > 0 ? log1p(Double(commit.lineCount)) / peak : 0
                let height = max(5, (size.height - 2) * CGFloat(scale))
                let rect = CGRect(x: x, y: size.height - 1 - height, width: 2, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Self.color(commit.link)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Commit timeline")
        .accessibilityValue("\(commits.count) commits, \(commits.filter { $0.link == .coAuthored || $0.link == .sameFiles }.count) tied to an agent by co-author or files")
        .help("\(commits.count) commits over the period · taller ticks changed more lines · cyan: an agent is named or edited the same files")
    }

    static func color(_ link: ShippedCodeReport.Link?) -> Color {
        switch link {
        case .coAuthored: return BridgeTheme.brand
        case .sameFiles: return BridgeTheme.brand.opacity(0.65)
        case .duringSession: return BridgeTheme.textSecondary
        case nil: return BridgeTheme.textTertiary
        }
    }
}

private extension ShippedCodeReport.Commit {
    var lineCount: Int { (commit.additions ?? 0) + (commit.deletions ?? 0) }
}
