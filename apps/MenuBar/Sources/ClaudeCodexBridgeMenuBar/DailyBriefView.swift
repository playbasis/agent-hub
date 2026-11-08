import AppKit
import BridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct DailyBriefView: View {
    @ObservedObject var journal: DailyBriefModel
    var hasActivity: Bool
    var collectedAt: Date?
    var create: () -> Void
    @State private var expanded: Set<String> = []

    private var groups: [(day: String, entries: [ActivityJournalEntry])] {
        Dictionary(grouping: journal.entries, by: \.date)
            .map { (day: $0.key, entries: $0.value.sorted { $0.revision > $1.revision }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { introduction; Spacer(minLength: 8); actions }
                VStack(alignment: .leading, spacing: 12) { introduction; actions }
            }

            if !journal.isConnected {
                Label("Connecting to saved briefs…", systemImage: "network")
                    .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
            }

            if let error = journal.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.warning)
                    .textSelection(.enabled).accessibilityIdentifier("hub.brief.error")
            }
            if let notice = journal.notice {
                Label(notice, systemImage: "checkmark.circle.fill")
                    .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.success)
                    .accessibilityIdentifier("hub.brief.notice")
            }
            if journal.isLoading && !journal.hasLoaded {
                HStack { ProgressView().controlSize(.small); Text("Loading saved briefs…") }
                    .font(BridgeFont.secondary).padding(20)
            } else if journal.hasLoaded && journal.entries.isEmpty {
                HubEmptyState(icon: "book.closed", title: "No briefs yet",
                              message: "A brief keeps a day's work, progress and follow-ups in one place. It's built on this Mac; nothing is sent to an AI model.")
            }
            ForEach(groups, id: \.day) { group in
                if let latest = group.entries.first {
                    card(latest)
                    if group.entries.count > 1 {
                        DisclosureGroup("Earlier versions · \(group.entries.count - 1)") {
                            VStack(spacing: 12) { ForEach(Array(group.entries.dropFirst())) { card($0) } }.padding(.top, 8)
                        }.font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hub.brief.page")
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            AcceptanceProbe.handleSafe(note, scope: "journal", state: {
                let present = Set(journal.entries.map(\.id))
                var state = AcceptanceProbe.serviceFields(loading: journal.isLoading, ready: journal.hasLoaded, hasData: !journal.entries.isEmpty,
                    error: journal.isConnected && journal.errorMessage != nil, unsupported: RefreshAcceptance.isReplayMode && !journal.isConnected, itemCount: journal.entries.count)
                state["expanded"] = expanded.intersection(present).sorted().joined(separator: ",")
                return state
            }, exercise: {
                guard journal.hasLoaded, !journal.isLoading, journal.errorMessage == nil, let entry = journal.entries.first else { return false }
                expanded.insert(entry.id)
                return true
            })
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Your days at a glance").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
            Text(hasActivity ? "Each brief is saved. Updating today's adds a new version and keeps the old ones."
                             : "Refresh activity first so there's work to summarise.")
                .font(BridgeFont.caption).foregroundStyle(hasActivity ? BridgeTheme.textSecondary : BridgeTheme.warning)
        }
    }

    private var hasTodaysBrief: Bool {
        guard let latest = journal.entries.map(\.date).max() else { return false }
        return latest == todayKey
    }

    private var todayKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = ActivityAnalytics.reportingTimeZone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button { Task { await journal.load() } } label: {
                if journal.isLoading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(BridgeIconButtonStyle(size: 28))
            .disabled(journal.isLoading || journal.isPublishing || !journal.isConnected)
            .keyboardShortcut("r", modifiers: .command)
            .help("Reload saved briefs (⌘R)").accessibilityLabel("Reload saved briefs")
            .accessibilityIdentifier("hub.brief.refresh")
            Button(action: create) {
                Label(journal.isPublishing ? "Saving…" : hasTodaysBrief ? "Update today's brief" : "Create today's brief",
                      systemImage: hasTodaysBrief ? "arrow.triangle.2.circlepath" : "plus")
            }
            .buttonStyle(BridgePrimaryButtonStyle(compact: true))
            .disabled(journal.isPublishing || !journal.isConnected || !hasActivity)
            .help(collectedAt.map { "Uses the activity read \(ActivityFormat.relative($0, now: Date()))" } ?? "Uses the latest activity read")
            .accessibilityIdentifier("hub.brief.create")
        }
    }

    private func card(_ entry: ActivityJournalEntry) -> some View {
        let sections = DailyBriefSection.parse(entry.markdown)
        let digest = DailyBriefDigest.parse(entry)
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displayDate(entry.date)).font(BridgeFont.title).foregroundStyle(BridgeTheme.textPrimary)
                Text("Version \(entry.revision) · \(displayTimestamp(entry.generatedAt, day: entry.date))")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                Spacer(minLength: 4)
                Button { export(entry) } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(BridgeIconButtonStyle(size: 28))
                    .accessibilityLabel("Export brief for \(entry.date), version \(entry.revision)")
                    .help("Save this brief as a Markdown file")
            }
            if digest.hasFigures {
                figures(digest)
                if !digest.projects.isEmpty { projects(digest.projects) }
                ForEach(digest.goals.prefix(3)) { goalRow($0) }
            } else {
                ForEach(Array(entry.outcomes.enumerated()), id: \.offset) { _, outcome in
                    Text(outcome).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).textSelection(.enabled)
                }
            }
            DisclosureGroup(isExpanded: Binding(
                get: { expanded.contains(entry.id) },
                set: { value in if value { expanded.insert(entry.id) } else { expanded.remove(entry.id) } }
            )) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections.filter { !$0.isTechnical && $0.title != "Observed work" }) { section in
                        documentSection(section)
                    }
                    DisclosureGroup("Sources · \(entry.evidenceIDs.count) records") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Saved as a snapshot in \(entry.timezone). These records back the brief up; they don't prove that work shipped.")
                                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                            ForEach(sections.filter(\.isTechnical)) { documentSection($0) }
                            Text("Snapshot \(entry.snapshotDigest)").font(BridgeFont.mono).textSelection(.enabled)
                        }.padding(.top, 8)
                    }.font(BridgeFont.secondary)
                }.padding(.top, 12)
            } label: { Text("Full brief").font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).bridgeCard(padding: 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hub.brief.\(entry.id)")
    }

    private func figures(_ digest: DailyBriefDigest) -> some View {
        var items: [StatStrip.Item] = []
        if let minutes = digest.activeMinutes {
            items.append(.init(value: digest.activeTimeBelowMinute ? "<1m" : ActivityFormat.duration(Double(minutes) * 60), label: "active time", icon: "clock",
                               help: "Time with at least one agent working, overlaps counted once"))
        }
        if let tokens = digest.tokens { items.append(.init(value: (digest.tokensArePartial ? "≥" : "") + ActivityFormat.compact(tokens), label: "tokens", icon: "circle.hexagongrid", help: "Saved report's known local subtotal; historical report versions retain their original method")) }
        if let sessions = digest.sessions { items.append(.init(value: sessions.formatted(), label: sessions == 1 ? "session" : "sessions", icon: "rectangle.stack")) }
        if let steps = digest.modelSteps {
            let value = steps == 0 && digest.modelStepsArePartial ? "—" : (digest.modelStepsArePartial ? "≥" : "") + steps.formatted()
            items.append(.init(value: value, label: "model steps", icon: "cpu"))
        }
        if let records = digest.nativeRecordsFinished {
            items.append(.init(value: records.formatted(), label: "requests finished", icon: "checkmark.circle",
                               help: "Saved requests (native records) that finished that day"))
        } else if let steps = digest.stepsFinished {
            items.append(.init(value: steps.formatted(), label: "requests finished", icon: "checkmark.circle",
                               help: "Finished steps, as counted by the older brief format this version was saved with"))
        }
        if let tools = digest.toolUses { items.append(.init(value: tools.formatted(), label: "tool uses", icon: "wrench.and.screwdriver")) }
        if let files = digest.fileChanges {
            items.append(.init(value: files.formatted(), label: "files changed", icon: "doc.badge.ellipsis",
                               help: digest.commits.map { "\($0) Git \($0 == 1 ? "commit" : "commits") seen today" }))
        }
        return StatStrip(items: items).padding(.vertical, 10).bridgeWell(cornerRadius: 10)
    }

    private func projects(_ projects: [DailyBriefDigest.Project]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(projects.prefix(6)) { project in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(BridgeTheme.brand).frame(width: 14)
                    Text(project.name).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                    if let count = project.sessions {
                        Text("\(count) \(count == 1 ? "session" : "sessions")").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    }
                    Spacer(minLength: 8)
                    ForEach(project.models.prefix(3), id: \.self) { model in
                        Tag(text: ModelNaming.display(model), color: model.lowercased().hasPrefix("claude") ? BridgeTheme.claude : BridgeTheme.codex)
                            .help(model)
                    }
                }
            }
            if projects.count > 6 {
                Text("+\(projects.count - 6) more in the full brief").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            }
        }
    }

    private func goalRow(_ goal: DailyBriefDigest.Goal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "scope").font(.system(size: 11, weight: .semibold)).foregroundStyle(BridgeTheme.success).frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Open goal").font(BridgeFont.micro).tracking(0.4).foregroundStyle(BridgeTheme.success)
                Text(goal.objective).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(goal.objective)
            }
            Spacer(minLength: 8)
            if let minutes = goal.minutes {
                Text(ActivityFormat.duration(Double(minutes) * 60)).font(BridgeFont.captionMedium.monospacedDigit())
                    .foregroundStyle(BridgeTheme.textSecondary).help("Working time Codex reports for this goal so far")
            }
        }
        .padding(10)
        .background(BridgeTheme.success.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func displayDate(_ value: String) -> String {
        guard let date = ActivityAnalytics.accountDate(value) else { return value }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return formatter.string(from: date)
    }

    /// "saved 02:34", or "saved 4 Nov, 09:10" when saved on a later day.
    private func displayTimestamp(_ value: Date, day: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = ActivityAnalytics.reportingTimeZone
        let key = DateFormatter()
        key.locale = Locale(identifier: "en_US_POSIX"); key.calendar = formatter.calendar
        key.timeZone = formatter.timeZone; key.dateFormat = "yyyy-MM-dd"
        formatter.setLocalizedDateFormatFromTemplate(key.string(from: value) == day ? "jmm" : "dMMMjmm")
        return "saved " + formatter.string(from: value)
    }

    private func documentSection(_ section: DailyBriefSection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(DailyBriefText.plain(section.title)).font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
            ForEach(Array(section.lines.enumerated()), id: \.offset) { _, line in
                // Only the decoded characters reach SwiftUI, never link,
                // image, HTML or other rich-text attributes.
                Text(DailyBriefText.plain(line))
                    .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func export(_ entry: ActivityJournalEntry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agent-hub-brief-\(entry.date)-v\(entry.revision).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(entry.markdown.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            journal.reportExport(.success(()))
        } catch { journal.reportExport(.failure(error)) }
    }
}
