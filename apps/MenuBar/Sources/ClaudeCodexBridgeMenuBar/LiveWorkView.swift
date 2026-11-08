import BridgeCore
import SwiftUI

private struct LiveContentVisibilityKey: EnvironmentKey { static let defaultValue = false }
private extension EnvironmentValues {
    /// Combines page coverage, attachment, and actual AppKit window visibility.
    var liveContentVisible: Bool {
        get { self[LiveContentVisibilityKey.self] }
        set { self[LiveContentVisibilityKey.self] = newValue }
    }
}

/// The top of the Sessions page: who is working right now and on what.
/// One headline, then a card per job (a top-level session with the
/// sub-agents working under it), then work that finished in the last hour.
/// Times are measured against the snapshot, so the page agrees with itself.
struct LiveWorkView: View {
    var summary: LiveWork.Summary
    var assignments: [String: AgentPersonaCatalog.Assignment]
    var now: Date
    var projectName: (String?) -> String
    var selectedID: String?
    var select: (String) -> Void
    var goals: [ActivityGoal] = []
    var feed: [LiveFeed.Event] = []
    /// Opens the turn drawer; a nil turn means the session's latest.
    var inspect: (String, String?) -> Void = { _, _ in }

    @State private var width: CGFloat = 0
    @State private var appeared = false
    @State private var windowVisible = false
    @Environment(\.activityContentVisible) private var contentVisible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let sideBySideWidth: CGFloat = 780

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if width >= Self.sideBySideWidth {
                HStack(alignment: .top, spacing: 14) {
                    jobs.frame(maxWidth: .infinity, alignment: .topLeading)
                    LiveFeedView(events: feed, assignments: assignments, inspect: inspect).frame(width: 290)
                }
            } else {
                jobs
                LiveFeedView(events: feed, assignments: assignments, inspect: inspect)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { width = proxy.size.width }
                .onChange(of: proxy.size.width) { width = $0 }
        })
        .background(HydrationWindowVisibility { windowVisible = $0 }.allowsHitTesting(false))
        .environment(\.liveContentVisible, appeared && contentVisible && windowVisible)
        .onAppear { appeared = true }
        .onDisappear { appeared = false }
        .transaction { transaction in
            if reduceMotion || !appeared || !contentVisible || !windowVisible {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.sessions.live")
    }

    private var jobs: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(summary.active.prefix(6)) { job in
                JobCard(job: job, assignments: assignments, now: now, projectName: projectName,
                        selectedID: selectedID, select: select, inspect: inspect, goals: goals)
                    .transition(reduceMotion ? .identity : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
            if summary.active.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz").font(.system(size: 14)).foregroundStyle(BridgeTheme.textTertiary)
                    Text("No recent recorded work. New evidence appears here as it arrives.")
                        .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(BridgeTheme.surface, in: RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous))
            }
            if summary.active.count > 6 {
                Text("\(summary.active.count - 6) more active below")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            }
            if !summary.finished.isEmpty { finished }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86), value: summary.active.map(\.id))
    }

    // MARK: Headline

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            LivePulse(state: summary.workingAgents > 0 ? .working : summary.active.isEmpty ? nil : .quiet,
                      evidenceAt: LiveAnimationPolicy.newestEvidence(summary.active.flatMap(\.agents).filter { $0.state == .working }.map(\.activityTimestamp), now: now), size: 8)
                .frame(width: 8)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(headline).font(.system(size: 17, weight: .semibold)).foregroundStyle(BridgeTheme.textPrimary)
            if let detail { Text(detail).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1) }
            Spacer(minLength: 8)
            InfoButton(title: "How this is measured", text: "Active means recent recorded model-step or turn evidence, not a verified running process. Quiet means an open record has no recent evidence; it may be waiting or its finish may be missing. Focus labels summarize recorded tool categories, not continuous execution. Goal links require explicit native relationships.")
        }
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        let working = summary.workingAgents
        if working > 0 { return "\(working) \(working == 1 ? "agent" : "agents") recently active" }
        let quiet = summary.active.count
        if quiet > 0 { return "\(quiet) quiet \(quiet == 1 ? "job" : "jobs")" }
        return "No recent agent activity"
    }

    private var detail: String? {
        let active = summary.active
        if summary.workingAgents > 0 {
            var parts: [String] = []
            let jobs = active.filter { $0.state == .working }.count
            parts.append("on \(jobs) \(jobs == 1 ? "job" : "jobs")")
            if summary.workingSubAgents > 0 { parts.append("\(summary.workingSubAgents) as sub-agents") }
            if summary.workingProjects > 1 { parts.append("in \(summary.workingProjects) projects") }
            return parts.joined(separator: " · ")
        }
        if let last = summary.lastActivity { return "Last activity \(ActivityFormat.relative(last, now: now))" }
        return nil
    }

    // MARK: Finished

    private var finished: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Finished in the last hour").font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textTertiary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { finishedChips(limit: 4) }
                HStack(spacing: 6) { finishedChips(limit: 2) }
                HStack(spacing: 6) { finishedChips(limit: 1) }
            }
        }
    }

    @ViewBuilder private func finishedChips(limit: Int) -> some View {
        ForEach(summary.finished.prefix(limit)) { job in
            let lead = job.lead
            Button { inspect(lead.id, lead.nativeTurnIDs.last) } label: {
                HStack(spacing: 6) {
                    Image(systemName: lead.failed ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(lead.failed ? BridgeTheme.danger : BridgeTheme.textTertiary)
                    Text(ActivityFormat.headline(ActivityTitles.display(lead.title, provider: lead.provider, projectPath: lead.projectPath), limit: 42))
                        .foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                    Text(ActivityFormat.relative(lead.finishedAt ?? lead.lastActivity, now: now))
                        .foregroundStyle(BridgeTheme.textTertiary).monospacedDigit()
                }
                .font(BridgeFont.caption)
                .padding(.horizontal, 9).frame(height: 24)
                .background(Color.white.opacity(0.05), in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help((lead.failed ? "Stopped with an error" : "Finished \(ActivityFormat.relative(lead.finishedAt ?? lead.lastActivity, now: now))") + ". Click to inspect its last turn.")
            .contextMenu { Button("Session details") { select(lead.id) } }
        }
        if summary.finished.count > limit {
            Text("+\(summary.finished.count - limit)").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
        }
    }
}

// MARK: - Job card

private struct JobCard: View {
    var job: LiveWork.Job
    var assignments: [String: AgentPersonaCatalog.Assignment]
    var now: Date
    var projectName: (String?) -> String
    var selectedID: String?
    var select: (String) -> Void
    var inspect: (String, String?) -> Void
    var goals: [ActivityGoal]

    private static let helperLimit = 4
    private var stepCount: Int { job.agents.reduce(0) { $0 + $1.modelStepIDs.count } }

    var body: some View {
        let lead = job.lead
        let assignment = assignments[lead.id]
        let selected = selectedID == lead.id
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                AgentPortrait(persona: assignment?.persona, provider: lead.provider, size: 36, recent: job.state == .working)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ActivityFormat.headline(ActivityTitles.display(lead.title, provider: lead.provider, projectPath: lead.projectPath), limit: 96))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                        .help(lead.title)
                    Text(meta(lead, assignment: assignment))
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(spacing: 6) {
                        NewStepsBadge(count: stepCount)
                        StatusPill(agent: lead, jobState: job.state,
                                   evidenceAt: LiveAnimationPolicy.newestEvidence(job.agents.filter { $0.state == .working }.map(\.activityTimestamp), now: now), now: now)
                    }
                    if job.state == .working, job.lastActivity > .distantPast {
                        LiveAgo(date: job.lastActivity, prefix: "Last evidence ")
                            .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                    }
                }
            }
            if lead.focus != nil || lead.pulse != nil, lead.state != .finished || job.helpers.isEmpty {
                ActivityLine(agent: lead, now: now, compact: false)
                    .padding(.leading, 48)
            }
            if let link = lead.goalAssociation {
                if link.state == .matched, let id = link.goalID,
                   goals.first(where: { $0.id == id }).map({ ActivityFormat.headline($0.objective) }) != ActivityFormat.headline(lead.title) {
                    Label(goals.first { $0.id == id }.map { ActivityFormat.headline($0.objective, limit: 140) } ?? "Recorded goal \(id)", systemImage: "scope")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.brand).lineLimit(2)
                        .help("Linked through recorded native evidence: \(link.reason)")
                } else if link.state == .ambiguous {
                    Label("Goal link needs clarification", systemImage: "questionmark.circle")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning).help(link.reason)
                }
            }
            if !job.helpers.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(helperHeading).font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textTertiary)
                        .padding(.bottom, 2)
                    ForEach(job.helpers.prefix(Self.helperLimit)) { helper in
                        HelperRow(agent: helper, assignment: assignments[helper.id], now: now,
                                  selected: selectedID == helper.id, select: select, inspect: inspect)
                    }
                    if job.helpers.count > Self.helperLimit {
                        Text("+\(job.helpers.count - Self.helperLimit) more").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                            .padding(.leading, 8)
                    }
                }
                .padding(.leading, 48)
            }
        }
        .padding(14)
        .background(BridgeTheme.surface, in: RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous))
        .overlay(alignment: .leading) {
            // A thin state rail: the card's status is readable before any text.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(LiveStateDot.color(job.state)).frame(width: 3).padding(.vertical, 14)
        }
        .overlay(RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous)
            .strokeBorder(selected ? BridgeTheme.brand.opacity(0.5) : BridgeTheme.surfaceBorder, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { inspect(lead.id, lead.nativeTurnIDs.last) }
        .contextMenu {
            Button("Inspect latest turn") { inspect(lead.id, lead.nativeTurnIDs.last) }
            Button("Session details") { select(lead.id) }
        }
        .help("Click to inspect the latest turn")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary(lead, assignment: assignment))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Inspect the latest turn")
    }

    private var helperHeading: String {
        let working = job.helpers.filter { $0.state == .working }.count
        let count = job.helpers.count
        return working == count ? "Sub-agents · \(working) working" : "Sub-agents · \(working) working, \(count - working) quiet"
    }

    private func meta(_ agent: LiveWork.Agent, assignment: AgentPersonaCatalog.Assignment?) -> String {
        var parts: [String] = []
        if let persona = assignment?.persona { parts.append(persona.firstName) }
        if let role = assignment?.role { parts.append(role.title) }
        if let model = agent.model { parts.append(ModelNaming.display(model)) }
        parts.append(projectName(agent.projectPath))
        return parts.joined(separator: " · ")
    }

    private func accessibilitySummary(_ agent: LiveWork.Agent, assignment: AgentPersonaCatalog.Assignment?) -> String {
        var text = "\(ActivityFormat.headline(ActivityTitles.display(agent.title, provider: agent.provider, projectPath: agent.projectPath), limit: 96)). \(StatusPill.text(agent: agent, jobState: job.state, now: now))"
        if let focus = agent.focus, agent.state != .finished { text += ". \(focus.title)" }
        let working = job.helpers.filter { $0.state == .working }.count
        if working > 0 { text += ". \(working) sub-\(working == 1 ? "agent" : "agents") working" }
        return text
    }
}

private struct HelperRow: View {
    var agent: LiveWork.Agent
    var assignment: AgentPersonaCatalog.Assignment?
    var now: Date
    var selected: Bool
    var select: (String) -> Void
    var inspect: (String, String?) -> Void

    private var title: String {
        ActivityTitles.isPlaceholder(agent.title) ? ActivityTitles.providerName(agent.provider) + " sub-agent"
            : ActivityFormat.headline(ActivityTitles.display(agent.title, provider: agent.provider, projectPath: agent.projectPath), limit: 60)
    }

    var body: some View {
        Button { inspect(agent.id, agent.nativeTurnIDs.last) } label: {
            HStack(spacing: 9) {
                AgentPortrait(persona: assignment?.persona, provider: agent.provider, size: 22, recent: agent.state == .working, showBadge: false)
                    .overlay(alignment: .bottomTrailing) {
                        LivePulse(state: agent.state, evidenceAt: agent.activityTimestamp, size: 4,
                                  fast: (agent.stepsLastFiveMinutes ?? 0) >= 10)
                    }
                Text(title).font(BridgeFont.secondary)
                    .foregroundStyle(BridgeTheme.textPrimary.opacity(agent.state == .working ? 0.92 : 0.6)).lineLimit(1)
                if let persona = assignment?.persona {
                    Text(persona.firstName).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                ActivityLine(agent: agent, now: now, compact: true)
                Group {
                    if agent.state == .working { LiveAgo(date: agent.lastActivity) }
                    else { Text("quiet \(ActivityFormat.duration(now.timeIntervalSince(agent.lastActivity)))") }
                }
                .font(BridgeFont.micro.monospacedDigit())
                .foregroundStyle(agent.state == .working ? BridgeTheme.success : BridgeTheme.textTertiary)
                .frame(minWidth: 56, alignment: .trailing)
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(selected ? Color.white.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contextMenu { Button("Session details") { select(agent.id) } }
        .help("Click to inspect this sub-agent's latest turn")
        .accessibilityLabel("\(title), \(agent.state == .working ? "working" : "quiet")\(agent.focus.map { ", \($0.title)" } ?? "")")
    }
}

/// What an agent is doing (from its current turn's tools) and a pulse of its
/// model steps per minute over the last half hour.
private struct ActivityLine: View {
    var agent: LiveWork.Agent
    var now: Date
    var compact: Bool

    var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            if let focus = agent.focus {
                let color = BridgeTheme.category(focus.category)
                Image(systemName: BridgeTheme.categorySymbol(focus.category))
                    .font(.system(size: compact ? 9 : 10.5, weight: .semibold)).foregroundStyle(color)
                    .frame(width: compact ? 12 : 16)
                Text(focus.title).font(compact ? BridgeFont.caption : BridgeFont.secondaryMedium)
                    .foregroundStyle(compact ? BridgeTheme.textSecondary : BridgeTheme.textPrimary).lineLimit(1)
                if !compact, let calls = agent.toolCallCount, calls > 0 {
                    Text("· \(agent.toolCallsArePartial ? "≥" : "")\(calls) recorded tool \(calls == 1 ? "call" : "calls")")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                }
            }
            if !compact {
                if !agent.changedFiles.isEmpty {
                    Label(agent.changedFiles.joined(separator: ", "), systemImage: "doc")
                        .labelStyle(CompactLabelStyle()).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                        .help("Files changed in this turn")
                }
                Spacer(minLength: 8)
            }
            if let pulse = agent.pulse {
                MiniBars(values: pulse.map(Double.init), tint: agent.state == .working ? BridgeTheme.success : BridgeTheme.textTertiary,
                         emphasis: pulse.count - 1, height: compact ? 12 : 18)
                    .frame(width: compact ? 54 : 110)
                    .help(pulseHelp(pulse))
                    .accessibilityLabel(pulseHelp(pulse))
                if !compact, let recent = agent.stepsLastFiveMinutes {
                    Text(recent == 0 ? "none in 5 min" : "\(recent) in 5 min").font(BridgeFont.micro.monospacedDigit())
                        .foregroundStyle(BridgeTheme.textTertiary).frame(minWidth: 62, alignment: .trailing)
                }
            }
        }
    }

    private func pulseHelp(_ pulse: [Int]) -> String {
        "Recorded model-step evidence in the last \(pulse.count) minutes, one bar per minute. Missing detail is not measured zero activity."
    }
}

/// "Working · 1h 12m", "Quiet · 12m", "Finished 8m ago".
private struct StatusPill: View {
    var agent: LiveWork.Agent
    var jobState: LiveWork.State
    var evidenceAt: Date?
    var now: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = displayState
        HStack(spacing: 6) {
            LivePulse(state: state, evidenceAt: evidenceAt, size: 6, fast: (agent.stepsLastFiveMinutes ?? 0) >= 10)
            Text(Self.text(agent: agent, jobState: jobState, now: now)).font(BridgeFont.captionMedium.monospacedDigit())
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: state)
        .foregroundStyle(state == .working ? BridgeTheme.success : state == .quiet ? BridgeTheme.warning : BridgeTheme.textSecondary)
        .padding(.horizontal, 9).frame(height: 22)
        .background(LiveStateDot.color(state).opacity(0.12), in: Capsule())
        .help(Self.help(agent: agent, state: state, now: now))
    }

    private var displayState: LiveWork.State {
        // A lead with no recent record of its own still heads working helpers.
        agent.state == .finished && agent.finishedAt == nil ? jobState : agent.state
    }

    static func text(agent: LiveWork.Agent, jobState: LiveWork.State, now: Date) -> String {
        let state = agent.state == .finished && agent.finishedAt == nil ? jobState : agent.state
        switch state {
        case .working:
            if agent.state == .working { return "Recent span · \(ActivityFormat.duration(max(0, now.timeIntervalSince(agent.stretchStart))))" }
            return "Sub-agents active"
        case .quiet: return agent.activityTimestamp == nil ? "No recent lead evidence" : "Quiet · \(ActivityFormat.duration(now.timeIntervalSince(agent.lastActivity)))"
        case .finished:
            return agent.failed ? "Stopped \(ActivityFormat.relative(agent.finishedAt, now: now))" : "Finished \(ActivityFormat.relative(agent.finishedAt ?? agent.lastActivity, now: now))"
        }
    }

    static func help(agent: LiveWork.Agent, state: LiveWork.State, now: Date) -> String {
        switch state {
        case .working: return "Recent evidence since \(agent.stretchStart.formatted(date: .omitted, time: .shortened)), with no recorded gap over ten minutes. This includes waits and is not verified process runtime. " + agent.evidenceDetails.joined(separator: " ")
        case .quiet: return "Its turn is still open, but nothing new has arrived for \(ActivityFormat.duration(now.timeIntervalSince(agent.lastActivity))). It may be running a long command or waiting for you."
        case .finished: return agent.failed ? "Its last turn ended with an error" : "Its last turn finished"
        }
    }
}

/// A small status dot. Static: a perpetual pulse would redraw the window
/// every frame.
struct LiveStateDot: View {
    var state: LiveWork.State?
    var size: CGFloat = 8

    static func color(_ state: LiveWork.State?) -> Color {
        switch state {
        case .working?: return BridgeTheme.success
        case .quiet?: return BridgeTheme.warning
        default: return BridgeTheme.textTertiary
        }
    }

    var body: some View {
        Circle().fill(Self.color(state)).frame(width: size, height: size)
            .background(Circle().fill(Self.color(state).opacity(state == .working ? 0.25 : 0)).frame(width: size * 2, height: size * 2))
            .accessibilityHidden(true)
    }
}

// MARK: - Live signals

extension ActivityFormat {
    /// "12s ago" under a minute, then minutes and hours, for ticking labels.
    static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        guard let seconds = LiveAnimationPolicy.age(of: date, now: now), seconds < Double(Int.max) else { return "Time unavailable" }
        if seconds < 1 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        return relative(date, now: now)
    }
}

/// A state dot with a finite arrival burst for genuinely fresh evidence. The
/// dot's five-minute recent-state colour is not verified process liveness.
struct LivePulse: View {
    var state: LiveWork.State?
    var evidenceAt: Date?
    var size: CGFloat = 8
    var fast = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveContentVisible) private var visible
    @State private var run: PulseRun?
    @State private var lastPulsedAt: Date?

    private struct PulseRun {
        let id = UUID()
        var startedAt: Date
        var duration: TimeInterval
        var cycle: TimeInterval
    }

    private struct Request: Equatable {
        var timestamp: Double?
        var working: Bool
        var visible: Bool
        var reduceMotion: Bool
        var fast: Bool
    }

    private var request: Request {
        let timestamp = evidenceAt?.timeIntervalSinceReferenceDate
        return Request(timestamp: timestamp.flatMap { $0.isFinite ? $0 : nil }, working: state == .working,
                       visible: visible, reduceMotion: reduceMotion, fast: fast)
    }

    var body: some View {
        LiveStateDot(state: state, size: size)
            .overlay {
                if state == .working, !reduceMotion, visible, let run {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        let elapsed = context.date.timeIntervalSince(run.startedAt)
                        let phase = max(0, elapsed).truncatingRemainder(dividingBy: run.cycle) / run.cycle
                        let eased = 1 - pow(1 - phase, 3)
                        let fresh = LiveAnimationPolicy.pulseDuration(evidenceAt: evidenceAt, now: context.date) != nil
                        Circle().stroke(LiveStateDot.color(state), lineWidth: 1.2)
                            .frame(width: size, height: size)
                            .scaleEffect(1 + eased * 1.8)
                            .opacity(elapsed >= 0 && elapsed < run.duration && fresh ? (1 - eased) * 0.8 : 0)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .task(id: request) { @MainActor in
                guard !Task.isCancelled else { return }
                run = nil
                let now = Date()
                guard LiveAnimationPolicy.shouldPulse(evidenceAt: evidenceAt, after: lastPulsedAt, now: now,
                                                       working: state == .working, visible: visible, reduceMotion: reduceMotion),
                      let duration = LiveAnimationPolicy.pulseDuration(evidenceAt: evidenceAt, now: now, fast: fast) else { return }
                lastPulsedAt = evidenceAt
                let next = PulseRun(startedAt: now, duration: duration, cycle: LiveAnimationPolicy.cycleDuration(fast: fast))
                run = next
                // One cancelable lifetime, not a perpetual animation or timer.
                do { try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000)) }
                catch {
                    if run?.id == next.id { run = nil }
                    return
                }
                if run?.id == next.id { run = nil }
            }
            .onDisappear { run = nil }
    }
}

/// A relative time that ticks every second while the page is visible.
struct LiveAgo: View {
    var date: Date?
    var prefix = ""
    @Environment(\.liveContentVisible) private var visible

    var body: some View {
        if visible {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(prefix + ActivityFormat.ago(date, now: context.date))
            }
        } else {
            Text(prefix + ActivityFormat.ago(date, now: Date()))
        }
    }
}

/// "+3 new steps" for a few seconds when a refresh brings more model steps.
/// Nothing shows on first appearance; only growth is announced.
private struct NewStepsBadge: View {
    var count: Int
    @State private var previous: Int?
    @State private var shown: Int?
    @State private var token = UUID()
    @Environment(\.liveContentVisible) private var visible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Request: Equatable {
        var count: Int
        var visible: Bool
        var reduceMotion: Bool
    }

    var body: some View {
        Group {
            if visible, let shown {
                Text("+\(shown) new \(shown == 1 ? "step" : "steps")")
                    .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.success)
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(BridgeTheme.success.opacity(0.14), in: Capsule())
                    .transition(reduceMotion ? .identity : .scale(scale: 0.8).combined(with: .opacity))
                    .accessibilityLabel("\(shown) new model steps")
            }
        }
        .task(id: Request(count: count, visible: visible, reduceMotion: reduceMotion)) { @MainActor in
            guard !Task.isCancelled else { return }
            let current = UUID(); token = current
            let old = previous
            previous = count
            shown = nil
            guard visible, let old, count > old else { return }
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) { shown = count - old }
            do { try await Task.sleep(nanoseconds: 3_500_000_000) }
            catch { return }
            guard !Task.isCancelled, token == current else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { shown = nil }
        }
        .onDisappear { token = UUID(); shown = nil; previous = count }
    }
}

// MARK: - Just happened

/// Recent starts, finishes, failures and new sub-agents, newest first. Names
/// and times only. New rows slide in at the top.
private struct LiveFeedView: View {
    var events: [LiveFeed.Event]
    var assignments: [String: AgentPersonaCatalog.Assignment]
    var inspect: (String, String?) -> Void
    @Environment(\.liveContentVisible) private var visible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Just happened").font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.textTertiary)
                Spacer()
                InfoButton(title: "Just happened", text: "Turn starts, finishes, failures and new sub-agents from recorded times in the last hour of this view. Only names and times are shown, never prompt or result text. Repeats from one agent within ten minutes are combined into one line.")
            }
            if events.isEmpty {
                Text("Nothing new in the last hour.").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    .padding(.vertical, 6)
            } else if visible {
                TimelineView(.periodic(from: .now, by: 1)) { context in rows(now: context.date) }
            } else {
                rows(now: Date())
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BridgeTheme.surface, in: RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: BridgeTheme.radiusCard, style: .continuous).strokeBorder(BridgeTheme.surfaceBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.sessions.feed")
    }

    private func rows(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(events) { event in
                row(event, now: now)
                    .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: events.map(\.id))
    }

    private func row(_ event: LiveFeed.Event, now: Date) -> some View {
        let fresh = LiveAnimationPolicy.age(of: event.date, now: now).map { $0 < 120 } ?? false
        return Button { inspect(event.sessionID, event.turnID) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: Self.symbol(event.kind)).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Self.color(event.kind)).frame(width: 16).padding(.top, 1)
                (Text(event.title).fontWeight(.medium).foregroundColor(BridgeTheme.textPrimary)
                    + Text(" " + Self.verb(event)).foregroundColor(BridgeTheme.textSecondary))
                    .font(BridgeFont.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    if fresh { Circle().fill(BridgeTheme.brand).frame(width: 5, height: 5) }
                    Text(ActivityFormat.ago(event.date, now: now))
                }
                .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(fresh ? BridgeTheme.brand : BridgeTheme.textTertiary)
                .fixedSize()
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(event.kind == .joined ? "Click to inspect this sub-agent" : "Click to inspect this turn")
        .accessibilityLabel("\(event.title) \(Self.verb(event)), \(ActivityFormat.ago(event.date, now: now))")
    }

    static func verb(_ event: LiveFeed.Event) -> String {
        switch event.kind {
        case .started: return event.count > 1 ? "started \(event.count) turns" : "started a turn"
        case .finished: return event.count > 1 ? "finished \(event.count) turns" : "finished a turn"
        case .failed: return event.count > 1 ? "stopped with an error \(event.count) times" : "stopped with an error"
        case .interrupted: return "was interrupted"
        case .joined: return event.isHelper ? "joined as a sub-agent" : "started"
        }
    }

    static func symbol(_ kind: LiveFeed.Kind) -> String {
        switch kind {
        case .started: return "play.circle"
        case .finished: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .interrupted: return "pause.circle"
        case .joined: return "person.badge.plus"
        }
    }

    static func color(_ kind: LiveFeed.Kind) -> Color {
        switch kind {
        case .started: return BridgeTheme.success
        case .finished: return BridgeTheme.textSecondary
        case .failed: return BridgeTheme.danger
        case .interrupted: return BridgeTheme.warning
        case .joined: return BridgeTheme.brand
        }
    }
}

// MARK: - All sessions

/// The list's totals on one quiet line under an "All sessions" heading.
/// Drops trailing figures when narrow; every figure keeps its tooltip.
struct SessionStatsLine: View {
    var items: [StatStrip.Item]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text("All sessions").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary).fixedSize()
            ViewThatFits(in: .horizontal) {
                line(items)
                line(Array(items.prefix(3)))
                line(Array(items.prefix(1)))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func line(_ items: [StatStrip.Item]) -> some View {
        HStack(spacing: 14) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    if let icon = item.icon { Image(systemName: icon).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(BridgeTheme.textTertiary) }
                    Text(item.value).font(BridgeFont.captionMedium.monospacedDigit()).foregroundStyle(BridgeTheme.textPrimary)
                    Text(item.label).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                }
                .fixedSize()
                .help(item.help ?? item.label)
            }
        }
    }
}
