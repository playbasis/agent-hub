import BridgeCore
import SwiftUI

/// A context file's history: each version the Hub saw and each Git commit
/// that touched it, how many lines changed, and how much each was used.
struct ContextChangesView: View {
    var title: String
    var changes: [ContextFileChange]
    /// Names the file on each row when one timeline covers several files.
    var fileLabel: ((String) -> String)? = nil
    /// Uses while a change was in effect (loads, sessions); nil when unknown.
    var usage: (ContextFileChange) -> Int?
    var usageNoun: (Int) -> String
    var now: Date
    var info: String

    @State private var showAll = false
    private static let collapsedCount = 4

    var body: some View {
        let shown = showAll ? changes : Array(changes.prefix(Self.collapsedCount))
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                SectionTitle(text: title, icon: "clock.arrow.circlepath")
                InfoButton(title: title, text: info)
                Spacer()
            }
            if changes.isEmpty {
                Text("No changes seen yet. A new version is recorded each time the file changes.")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 1) {
                    ForEach(shown) { change in row(change) }
                }
                if changes.count > Self.collapsedCount {
                    Button(showAll ? "Show fewer" : "Show \(changes.count - Self.collapsedCount) older") {
                        withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.15)) { showAll.toggle() }
                    }
                    .buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.textSecondary))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func row(_ change: ContextFileChange) -> some View {
        HStack(alignment: .center, spacing: 9) {
            badge(change)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let fileLabel { Text(fileLabel(change.path)).font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1) }
                    Text(dateLabel(change.date)).font(fileLabel == nil ? BridgeFont.captionMedium : BridgeFont.caption)
                        .foregroundStyle(fileLabel == nil ? BridgeTheme.textPrimary : BridgeTheme.textSecondary)
                    if change.isCurrent { Tag(text: "Current", color: BridgeTheme.brand) }
                    ForEach(change.coAuthors, id: \.self) { agent in AgentAvatar(name: agent.rawValue.capitalized, size: 12) }
                }
                Text(detail(change)).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            if change.added != nil || change.removed != nil {
                LinesChangedLabel(lines: ShippedCodeReport.Lines(additions: change.added ?? 0, deletions: change.removed ?? 0), compact: true, font: BridgeFont.micro)
            }
            if let count = usage(change) {
                Text("\(count) \(usageNoun(count))").font(BridgeFont.micro.monospacedDigit())
                    .foregroundStyle(count > 0 ? BridgeTheme.textSecondary : BridgeTheme.textTertiary)
                    .frame(minWidth: 58, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .help(help(change))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func badge(_ change: ContextFileChange) -> some View {
        if let version = change.version {
            Text("v\(version)").font(.system(size: 9.5, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(change.isCurrent ? BridgeTheme.ink : BridgeTheme.textSecondary)
                .frame(width: 26, height: 18)
                .background(change.isCurrent ? BridgeTheme.brand : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary)
                .frame(width: 26, height: 18)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private func detail(_ change: ContextFileChange) -> String {
        var parts: [String] = []
        if let id = change.commitID { parts.append(String(id.prefix(7)) + (change.commitSubject.map { " " + $0 } ?? "")) }
        else if change.isFirstSeen { parts.append("First seen" + (change.lines.map { " · \($0) lines" } ?? "")) }
        else if let lines = change.lines { parts.append("\(lines) lines") }
        return parts.joined(separator: " · ")
    }

    private func help(_ change: ContextFileChange) -> String {
        var parts: [String] = []
        if let version = change.version { parts.append("Version \(version), seen by the Hub") }
        if let id = change.commitID { parts.append("Git commit \(id.prefix(12))" + (change.commitSubject.map { ": \($0)" } ?? "")) }
        parts.append("Changed \(change.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
        if change.isFirstSeen, change.commitID == nil { parts.append("Changes before this aren't known unless Git shows them") }
        if let count = usage(change) { parts.append("\(count) \(usageNoun(count)) while it was in effect, in this period") }
        return parts.joined(separator: "\n")
    }

    private func dateLabel(_ date: Date) -> String {
        now.timeIntervalSince(date) < 6 * 86_400 ? ActivityFormat.relative(date, now: now) : date.formatted(.dateTime.day().month(.abbreviated))
    }
}
