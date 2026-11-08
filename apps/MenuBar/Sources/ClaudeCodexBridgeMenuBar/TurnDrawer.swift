import AppKit
import BridgeCore
import SwiftUI

// MARK: - Selection

/// One recorded turn opened in the side drawer. The snapshot is frozen when
/// the drawer opens; stepping between turns keeps the same snapshot.
struct TurnInspectionSelection: Identifiable, Equatable {
    let id: UUID
    let overview: ActivityOverview
    let sessionID: String
    var turnID: String?
    let snapshotRevision: UInt64

    init(overview: ActivityOverview, sessionID: String, turnID: String?, id: UUID = UUID(), snapshotRevision: UInt64 = 0) {
        self.id = id; self.overview = overview; self.sessionID = sessionID
        self.snapshotRevision = snapshotRevision
        let now = overview.generatedAt
        // Resolve "latest" once, so highlights and the drawer agree.
        if let turnID { self.turnID = turnID }
        else {
            let records = TurnInspectionRecords(overview.sessions)
            var session = records.byID[sessionID]
            session?.turns = records.turns(in: sessionID)
            self.turnID = session.flatMap { TurnSequence.ordered($0, now: now).last?.id }
        }
    }

    /// The same open drawer on a newer snapshot, still on the same turn. Nil
    /// when that session or turn is no longer present.
    func rebased(on newer: ActivityOverview, revision: UInt64 = 0) -> TurnInspectionSelection? {
        guard newer.generatedAt >= overview.generatedAt,
              newer.generatedAt > overview.generatedAt || revision > snapshotRevision else { return nil }
        let records = TurnInspectionRecords(newer.sessions)
        guard let session = records.byID[sessionID],
              turnID.map({ id in session.turns.contains { $0.id == id } }) ?? true else { return nil }
        return TurnInspectionSelection(overview: newer, sessionID: sessionID, turnID: turnID, id: id, snapshotRevision: revision)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.turnID == rhs.turnID && lhs.overview.generatedAt == rhs.overview.generatedAt && lhs.snapshotRevision == rhs.snapshotRevision
    }
}

/// The turn the drawer shows, so timelines and lists can mark it.
struct InspectedTurn: Equatable {
    var sessionID: String
    var turnID: String?
}

private struct InspectedTurnKey: EnvironmentKey { static let defaultValue: InspectedTurn? = nil }

extension EnvironmentValues {
    var inspectedTurn: InspectedTurn? {
        get { self[InspectedTurnKey.self] }
        set { self[InspectedTurnKey.self] = newValue }
    }
}

// MARK: - Model

/// Resolves the selected turn and reads its tools and results on demand. One
/// shared reader serves every surface; stepping quickly reads only where the
/// person settles. Visible text stays in memory and is dropped when hidden.
@MainActor final class TurnDrawerModel: ObservableObject {
    struct Context {
        let session: ActivitySession
        let parent: ActivitySession?
        let turns: [ActivityTurn]
        let index: Int?
        /// The canonical observed ancestor that owns this copied turn.
        let copiedFrom: ActivitySession?
        let assignment: AgentPersonaCatalog.Assignment?
        let now: Date
        let revision: UInt64
        var turn: ActivityTurn? { index.map { turns[$0] } }
    }

    private struct ReadKey: Hashable {
        let sessionID: String
        let provider: AgentName
        let nativeID: String
        let turnID: String
        let includeText: Bool
        /// Open turns follow the snapshot; corrected closed metadata and source
        /// revisions invalidate reads too.
        let snapshot: Date?
        let revision: UInt64
        let turnFingerprint: String
    }

    typealias Reader = @Sendable (ActivitySession, ActivityTurn, Bool) async throws -> WorkEvidenceBatch

    private struct Request {
        let key: ReadKey
        let session: ActivitySession
        let turn: ActivityTurn
        let token: UUID
    }

    static let cacheLimit = 12

    @Published private(set) var context: Context?
    @Published private(set) var entries: [TurnTimeline.Entry] = [] {
        didSet { displayItems = TurnTimeline.fold(entries) }
    }
    /// Rows to draw: runs of repeated hand-offs fold into one, built once per read.
    private(set) var displayItems: [TurnTimeline.DisplayItem] = []
    @Published private(set) var batch: WorkEvidenceBatch?
    @Published private(set) var readAt: Date?
    @Published private(set) var reading = false
    @Published private(set) var error: String?

    private var cache: [ReadKey: (batch: WorkEvidenceBatch, at: Date)] = [:]
    private var cacheOrder: [ReadKey] = []
    private var current: ReadKey?
    private var task: Task<Void, Never>?
    private var pending: Request?
    private var requestToken = UUID()
    private let reader: Reader
    private let debounceNanoseconds: UInt64
    private let clock: () -> Date
    private let readsEnabled: Bool
    private var resolved: (id: UUID, sessionID: String, turnID: String?, generatedAt: Date, revision: UInt64)?
    private var assignments: (generatedAt: Date, revision: UInt64, values: [String: AgentPersonaCatalog.Assignment])?
    private var recordsCache: (id: UUID, generatedAt: Date, revision: UInt64, value: TurnInspectionRecords)?
    private(set) var recordsBuildCount = 0

    init(reader: Reader? = nil, debounceNanoseconds: UInt64 = 200_000_000, clock: @escaping () -> Date = Date.init) {
        self.reader = reader ?? { session, turn, text in try await Self.readEvidence(session, turn, text) }
        self.debounceNanoseconds = debounceNanoseconds
        self.clock = clock
        readsEnabled = reader != nil || !AcceptanceProbe.isActive
    }

    var counts: TurnTimeline.Counts { TurnTimeline.counts(entries) }

    func resolve(_ selection: TurnInspectionSelection) {
        guard resolved?.id != selection.id || resolved?.sessionID != selection.sessionID || resolved?.turnID != selection.turnID
            || resolved?.generatedAt != selection.overview.generatedAt || resolved?.revision != selection.snapshotRevision else { return }
        let sameTurn = resolved?.id == selection.id && resolved?.sessionID == selection.sessionID && resolved?.turnID == selection.turnID
        resolved = (selection.id, selection.sessionID, selection.turnID, selection.overview.generatedAt, selection.snapshotRevision)
        let overview = selection.overview
        let now = overview.generatedAt
        let records: TurnInspectionRecords
        if let cached = recordsCache, cached.id == selection.id, cached.generatedAt == now, cached.revision == selection.snapshotRevision {
            records = cached.value
        } else {
            records = TurnInspectionRecords(overview.sessions)
            recordsCache = (selection.id, now, selection.snapshotRevision, records); recordsBuildCount += 1
        }
        guard var session = records.byID[selection.sessionID] else {
            context = nil; entries = []; cancel()
            return
        }
        session.turns = records.turns(in: session.id)
        let turns = TurnSequence.ordered(session, now: now)
        let index: Int?
        if let requested = selection.turnID {
            index = turns.firstIndex { $0.id == requested }
        } else { index = turns.isEmpty ? nil : turns.count - 1 }
        let owner = index.flatMap { records.owner(of: turns[$0].id, in: session.id) }
        let copiedFrom = owner.flatMap { $0.id == session.id ? nil : $0 }
        if assignments?.generatedAt != now || assignments?.revision != selection.snapshotRevision {
            assignments = (now, selection.snapshotRevision, PersonaDirectory.assignments(for: overview))
        }
        context = Context(session: session, parent: records.parents[session.id].flatMap { records.byID[$0] }, turns: turns, index: index,
                          copiedFrom: copiedFrom, assignment: assignments?.values[session.id], now: now, revision: selection.snapshotRevision)
        // A newer snapshot of the same turn keeps what is on screen until
        // the next read replaces it.
        if !sameTurn || index == nil { cancel() }
        rebuild()
    }

    func load(includeText: Bool, force: Bool = false) {
        guard let context, let turn = context.turn else { cancel(); return }
        let open = TurnStatus(turn) == .inProgress
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let key = ReadKey(sessionID: context.session.id, provider: context.session.provider, nativeID: context.session.nativeID,
                          turnID: turn.id, includeText: includeText, snapshot: open ? context.now : nil,
                          revision: context.revision, turnFingerprint: TraceCrypto.digest((try? encoder.encode(turn)) ?? Data(String(reflecting: turn).utf8)))
        if !force, current == key, (batch != nil || reading) { return }
        let refreshing = current.map { $0.sessionID == key.sessionID && $0.turnID == key.turnID && $0.includeText == key.includeText } ?? false
        current = key
        requestToken = UUID(); pending = nil
        error = nil
        if !force, let cached = cache[key] {
            batch = cached.batch; readAt = cached.at; reading = false
            rebuild()
            return
        }
        if !refreshing { batch = nil; readAt = nil }
        rebuild()
        guard readsEnabled else { reading = false; return }
        reading = true
        // One worker owns the active read. While it finishes, repeated stepping
        // replaces one pending request instead of launching overlapping reads.
        pending = Request(key: key, session: context.session, turn: turn, token: requestToken)
        if task == nil { task = Task { [weak self] in await self?.drain() } }
    }

    private func drain() async {
        while let request = pending {
            pending = nil
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
                guard request.token == requestToken, current == request.key else { continue }
                let page = try await reader(request.session, request.turn, request.key.includeText)
                guard request.token == requestToken, current == request.key, !Task.isCancelled else { continue }
                let at = clock()
                remember(request.key, page, at: at)
                batch = page; readAt = at; reading = false
                rebuild()
            } catch {
                guard request.token == requestToken, current == request.key else { continue }
                if !(error is CancellationError) { self.error = TraceRedactor.redact(error.localizedDescription, maximumCharacters: 300) }
                reading = false
            }
        }
        task = nil
    }

    private nonisolated static func readEvidence(_ session: ActivitySession, _ turn: ActivityTurn, _ includeText: Bool) async throws -> WorkEvidenceBatch {
        for _ in 0 ..< 40 {
            try Task.checkCancellation()
            if !(await WorkEvidenceAccess.shared.isBusy) { break }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        return try await WorkEvidenceAccess.shared.read(session: session, turn: turn, includeText: includeText, cursor: nil)
    }

    /// Hiding text forgets every page that carried it.
    func forgetText() {
        let droppingCurrent = current?.includeText == true
        cache = cache.filter { !$0.key.includeText }
        cacheOrder.removeAll { $0.includeText }
        if droppingCurrent {
            requestToken = UUID(); pending = nil; current = nil; reading = false
        }
        // Entries also retain WorkEvidenceItem values, so clearing only the
        // cached page leaves opted-in text alive on screen and in memory.
        if droppingCurrent || batch?.items.contains(where: { $0.preview != nil }) == true {
            batch = nil; readAt = nil
        }
        rebuild()
    }

    func cancel() {
        requestToken = UUID(); pending = nil; current = nil; reading = false
        batch = nil; readAt = nil; error = nil
        forgetText()
        rebuild()
    }

    private func remember(_ key: ReadKey, _ page: WorkEvidenceBatch, at: Date) {
        cache[key] = (page, at)
        cacheOrder.removeAll { $0 == key }; cacheOrder.append(key)
        while cacheOrder.count > Self.cacheLimit { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    private func rebuild() {
        guard let context, let turn = context.turn else { entries = []; return }
        entries = TurnTimeline.build(steps: turn.modelSteps, items: batch?.items, now: context.now, nativeReadAt: readAt)
    }
}

// MARK: - Drawer

/// A trailing drawer for one recorded turn: who, when, how it ended, then
/// its steps, tools and results in order. ← → step through the session.
struct TurnDrawer: View {
    let selection: TurnInspectionSelection
    var focus: (String) -> Void
    var close: () -> Void
    var openReplay: (String, String?) -> Void
    var showSession: (String) -> Void

    @StateObject private var model = TurnDrawerModel()
    @State private var includeText = false
    @State private var expanded: Set<String> = []
    @State private var review: WorkEvidenceSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let context = model.context {
                header(context)
                Hairline()
                if let turn = context.turn {
                    summary(context, turn: turn)
                    Hairline()
                    timeline(context, turn: turn)
                    Hairline()
                    footer(context, turn: turn)
                } else {
                    message(selection.turnID == nil ? "No recorded turns in this session yet." : "This turn isn't in the current snapshot.", icon: "tray")
                }
            } else {
                HStack { Spacer(); closeButton }.padding(12)
                message("This session isn't in the current snapshot.", icon: "questionmark.folder")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BridgeTheme.inkRaised)
        .overlay(alignment: .leading) { Rectangle().fill(BridgeTheme.separator).frame(width: 1) }
        .shadow(color: .black.opacity(0.35), radius: 18, x: -6, y: 0)
        .background(DrawerKeyMonitor { step($0 == .earlier ? -1 : 1) }.allowsHitTesting(false))
        .onAppear { model.resolve(selection); model.load(includeText: includeText) }
        .onChange(of: selection) { value in
            // A newer snapshot of the same turn keeps open rows open.
            if model.context?.turn?.id != value.turnID || model.context?.session.id != value.sessionID { expanded = [] }
            model.resolve(value); model.load(includeText: includeText)
        }
        .onChange(of: includeText) { value in
            if !value { model.forgetText() }
            model.load(includeText: value)
        }
        .onDisappear { model.cancel(); model.forgetText() }
        .sheet(item: $review) { WorkEvidenceView(selection: $0) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.turn-drawer")
    }

    // MARK: Header

    private var closeButton: some View {
        Button(action: close) { Image(systemName: "xmark") }
            .buttonStyle(BridgeIconButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .accessibilityLabel("Close turn details")
    }

    private func header(_ context: TurnDrawerModel.Context) -> some View {
        let session = context.session
        let title = ActivityTitles.display(session.title, provider: session.provider, projectPath: session.projectPath,
                                           parentTitle: context.parent?.title)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                AgentPortrait(persona: context.assignment?.persona, provider: session.provider, size: 30,
                              recent: context.turn.map { TurnStatus($0) == .inProgress } ?? false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ActivityFormat.headline(title, limit: 90)).font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .help(session.title)
                    Text(meta(context)).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Menu {
                    Button("Session details") { showSession(session.id) }
                    Button("Open full replay") { openReplay(session.id, context.turn?.id) }
                    if let turn = context.turn {
                        Divider()
                        Button("Copy turn ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(turn.id, forType: .string)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(BridgeTheme.textSecondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More")
                .accessibilityLabel("More turn actions")
                closeButton
            }
            if let index = context.index {
                HStack(spacing: 4) {
                    Button { step(-1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(BridgeIconButtonStyle(size: 22)).disabled(index == 0)
                        .help("Earlier turn (←)").accessibilityLabel("Earlier turn")
                    Text("Turn \(index + 1) of \(context.turns.count)")
                        .font(BridgeFont.captionMedium.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary)
                        .frame(minWidth: 86)
                    Button { step(1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(BridgeIconButtonStyle(size: 22)).disabled(index >= context.turns.count - 1)
                        .help("Later turn (→)").accessibilityLabel("Later turn")
                    Spacer(minLength: 6)
                    if index < context.turns.count - 1, let last = context.turns.last {
                        Button("Latest") { focus(last.id) }.buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
                            .help("Jump to this session's most recent turn")
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
    }

    private func meta(_ context: TurnDrawerModel.Context) -> String {
        var parts: [String] = []
        if let persona = context.assignment?.persona { parts.append(persona.firstName) }
        if let role = context.assignment?.role { parts.append(role.title) }
        if context.session.isChild { parts.append("Sub-agent") }
        parts.append(ActivityFormat.project(context.session.projectPath))
        return parts.joined(separator: " · ")
    }

    // MARK: Summary

    private func summary(_ context: TurnDrawerModel.Context, turn: ActivityTurn) -> some View {
        let status = TurnStatus(turn)
        let counts = model.counts
        let models = Set(([turn.model] + (turn.modelSteps ?? []).map(\.model)).compactMap { $0 }.filter { !$0.isEmpty })
        let model = models.count > 1 ? "Mixed models" : models.first.map(ModelNaming.display)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TurnStatusBadge(status: status)
                Text(timeRange(turn, status: status, now: context.now))
                    .font(BridgeFont.caption.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                InfoButton(title: "About this turn", text: "A turn is one round of work recorded by the provider. Finished means the provider stopped responding, not that the work was right. Model steps are saved usage checkpoints, not exact API calls. Tools and results are read from the session's own history when you open a turn, and a result joins its tool only through a recorded ID. Hidden reasoning is never shown.")
            }
            HStack(spacing: 6) {
                if let model {
                    DrawerChip(icon: "cpu", text: model + (turn.effort.map { " · \($0)" } ?? ""))
                }
                if let steps = turn.modelSteps {
                    let count = Set(steps.map(\.id)).count
                    DrawerChip(icon: "bubble.left.and.text.bubble.right", text: "\(count) model \(count == 1 ? "step" : "steps")")
                }
                if self.model.batch != nil, counts.tools > 0 {
                    DrawerChip(icon: "wrench.and.screwdriver",
                               text: "\(counts.tools) \(counts.tools == 1 ? "tool" : "tools")" + (counts.failed > 0 ? " · \(counts.failed) failed" : ""),
                               tint: counts.failed > 0 ? BridgeTheme.danger : nil)
                } else if let tools = turn.toolCount, tools > 0 {
                    DrawerChip(icon: "wrench.and.screwdriver", text: "\(tools) \(tools == 1 ? "tool" : "tools") recorded")
                }
            }
            let skills = loadedSkills(turn)
            if !skills.isEmpty {
                HStack(spacing: 6) {
                    ForEach(skills.prefix(4), id: \.key) { skill in
                        Button { ActivityReportsController.shared.showSkill(skill.key) } label: {
                            DrawerChip(icon: "wand.and.stars", text: skill.name, tint: BridgeTheme.brand)
                        }
                        .buttonStyle(.plain)
                        .help("This turn loaded the \(skill.name) skill. Open it on the Skills page.")
                        .accessibilityLabel("Skill \(skill.name)")
                        .accessibilityHint("Open on the Skills page")
                    }
                    if skills.count > 4 {
                        Text("+\(skills.count - 4)").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    }
                }
            }
            if let copy = context.copiedFrom {
                Label("Also recorded in \(ActivityFormat.headline(ActivityTitles.display(copy.title, provider: copy.provider, projectPath: copy.projectPath), limit: 48)). It's counted once, there.",
                      systemImage: "doc.on.doc")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if !context.session.historyComplete {
                Label("Only part of this session's history was available.", systemImage: "clock.badge.questionmark")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    /// Distinct skills the turn loaded, in load order.
    private func loadedSkills(_ turn: ActivityTurn) -> [(key: String, name: String)] {
        var seen = Set<String>()
        return (turn.skills ?? []).filter { $0.isLoad && seen.insert($0.key).inserted }.map { ($0.key, $0.name) }
    }

    private func timeRange(_ turn: ActivityTurn, status: TurnStatus, now: Date) -> String {
        let start = turn.startedAt.flatMap { $0.timeIntervalSince1970.isFinite && $0 <= now ? $0 : nil }
        let end = turn.completedAt.flatMap { $0.timeIntervalSince1970.isFinite && $0 <= now ? $0 : nil }
        guard let start else { return "Start time not recorded" }
        let calendar = Calendar.current
        let sameDay = calendar.isDate(start, inSameDayAs: now)
        let startText = sameDay ? start.formatted(.dateTime.hour().minute().second()) : start.formatted(.dateTime.day().month().hour().minute())
        guard let end, end >= start else {
            return status == .inProgress ? "Started \(startText) · still open" : "Started \(startText) · end not recorded"
        }
        let endText = calendar.isDate(end, inSameDayAs: start) ? end.formatted(.dateTime.hour().minute().second()) : end.formatted(.dateTime.day().month().hour().minute())
        return "\(startText) → \(endText) · \(ActivityFormat.duration(end.timeIntervalSince(start)))"
    }

    // MARK: Timeline

    private func timeline(_ context: TurnDrawerModel.Context, turn: ActivityTurn) -> some View {
        let entries = model.entries
        let items = model.displayItems
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { offset, item in
                    let isLast = offset == items.count - 1 && !model.reading
                    switch item {
                    case let .entry(entry):
                        TurnTimelineRow(entry: entry, turnModel: turn.model, includeText: includeText, now: context.now,
                                        isFirst: offset == 0, isLast: isLast, expanded: binding(entry.id))
                    case let .repeats(run):
                        TurnRepeatRow(run: run, isFirst: offset == 0, isLast: isLast, expanded: binding(run.id)) {
                            ForEach(Array(run.entries.enumerated()), id: \.element.id) { index, entry in
                                TurnTimelineRow(entry: entry, turnModel: turn.model, includeText: includeText, now: context.now,
                                                isFirst: false, isLast: isLast && index == run.entries.count - 1, expanded: binding(entry.id))
                            }
                        }
                    }
                }
                if model.reading {
                    HydrationClock(identity: "turn-read") { t in
                        HStack(spacing: 8) {
                            HydrationGlyph(size: 12, t: t)
                            Text("Reading tools and results…").font(BridgeFont.caption).foregroundStyle(BridgeTheme.hydrationLabel)
                        }
                    }
                    .padding(.leading, 18).padding(.vertical, 10)
                    .accessibilityElement(children: .combine)
                }
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle").font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try again") { model.load(includeText: includeText, force: true) }
                            .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                if let batch = model.batch, batch.isPartial || batch.nextCursor != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "ellipsis.circle").foregroundStyle(BridgeTheme.textTertiary)
                        Text("Some events aren't shown here.").foregroundStyle(BridgeTheme.textTertiary)
                        Button("Open full replay") { openReplay(context.session.id, turn.id) }.buttonStyle(BridgeLinkButtonStyle(color: BridgeTheme.brand))
                    }
                    .font(BridgeFont.caption).padding(.horizontal, 16).padding(.vertical, 10)
                    .help(batch.message)
                }
                if entries.isEmpty, !model.reading, model.error == nil {
                    Text(AcceptanceProbe.isActive ? "Tool history isn't read during offline UI tests." : "No step-level detail was recorded for this turn.")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: .infinity)
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { value in
            if value { expanded.insert(id) } else { expanded.remove(id) }
        })
    }

    // MARK: Footer

    private func footer(_ context: TurnDrawerModel.Context, turn: ActivityTurn) -> some View {
        HStack(spacing: 8) {
            Toggle("Show text", isOn: $includeText)
                .toggleStyle(.switch).controlSize(.mini).font(BridgeFont.caption)
                .foregroundStyle(BridgeTheme.textSecondary)
                .disabled(AcceptanceProbe.isActive)
                .help("Read the redacted visible text of requests, replies and results for this turn. Shown on this Mac only and forgotten when you switch it off. Hidden reasoning is never shown.")
            Spacer(minLength: 6)
            Button {
                review = WorkEvidenceSelection(overview: selection.overview, sessionID: context.session.id, turnIDs: [turn.id])
            } label: { Label("Note", systemImage: "square.and.pencil") }
                .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                .help("Rate this turn and write a note for your next prompt. Saved on this Mac; nothing is sent.")
            Button { openReplay(context.session.id, turn.id) } label: { Label("Full replay", systemImage: "list.number") }
                .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                .help("Open the whole goal's sequence at this turn")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func message(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    @discardableResult private func step(_ delta: Int) -> Bool {
        guard let context = model.context, let index = context.index else { return false }
        let target = index + delta
        guard context.turns.indices.contains(target) else { return false }
        focus(context.turns[target].id)
        return true
    }
}

// MARK: - Pieces

struct TurnStatusBadge: View {
    var status: TurnStatus

    static func color(_ status: TurnStatus) -> Color {
        switch status {
        case .finished: return BridgeTheme.textSecondary
        case .failed: return BridgeTheme.danger
        case .interrupted: return BridgeTheme.warning
        case .inProgress: return BridgeTheme.success
        case .unknown: return BridgeTheme.textTertiary
        }
    }

    static func symbol(_ status: TurnStatus) -> String {
        switch status {
        case .finished: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        case .interrupted: return "pause.circle"
        case .inProgress: return "circle.dotted"
        case .unknown: return "questionmark.circle"
        }
    }

    var body: some View {
        let color = Self.color(status)
        Label(status.title, systemImage: Self.symbol(status))
            .labelStyle(CompactLabelStyle())
            .font(BridgeFont.captionMedium)
            .foregroundStyle(color)
            .padding(.horizontal, 8).frame(height: 20)
            .background(color.opacity(0.12), in: Capsule())
            .fixedSize()
    }
}

private struct DrawerChip: View {
    var icon: String
    var text: String
    var tint: Color? = nil

    var body: some View {
        Label(text, systemImage: icon)
            .labelStyle(CompactLabelStyle())
            .font(BridgeFont.caption.monospacedDigit())
            .foregroundStyle(tint ?? BridgeTheme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 7).frame(height: 20)
            .background((tint ?? Color.white).opacity(tint == nil ? 0.05 : 0.12), in: Capsule())
    }
}

/// One line per step on a continuous rail; detail opens in place.
/// A folded run of the same bookkeeping event: one row with its count and
/// time span, expanding to the original rows in order.
private struct TurnRepeatRow<Content: View>: View {
    var run: TurnTimeline.Repeat
    var isFirst: Bool
    var isLast: Bool
    @Binding var expanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    ZStack {
                        Image(systemName: run.kind == .handoff ? "arrow.triangle.branch" : "note.text")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(BridgeTheme.brand)
                    }
                    .frame(width: 18, height: 18).background(Circle().fill(BridgeTheme.inkRaised))
                    .frame(width: 20)
                    HStack(spacing: 6) {
                        Text("\(TurnTimelineRow.label(run.kind)) ×\(run.operationCount)").font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                        Text(run.title).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
                        if run.stepCount > 0 {
                            Text("· \(run.stepCount) model \(run.stepCount == 1 ? "step" : "steps")").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                        }
                    }
                    Spacer(minLength: 6)
                    Text(span).font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1).fixedSize()
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(BridgeTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.leading, 10).padding(.trailing, 14)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(run.operationCount) back-to-back \(TurnTimelineRow.label(run.kind).lowercased())s with only model steps between them. Expand to see each one.")
            .accessibilityElement(children: .combine)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                content().padding(.leading, 12)
            }
        }
        .background(alignment: .topLeading) {
            GeometryReader { proxy in
                Rectangle().fill(BridgeTheme.separator)
                    .frame(width: 1, height: max(0, proxy.size.height - (isFirst ? 15 : 0) - (isLast && !expanded ? proxy.size.height - 15 : 0)))
                    .offset(x: 19.5, y: isFirst ? 15 : 0)
            }
        }
    }

    private var span: String {
        func clock(_ date: Date) -> String { date.formatted(.dateTime.hour().minute().second()) }
        guard let first = run.first else { return "time not recorded" }
        guard let last = run.last, last > first else { return clock(first) }
        return clock(first) + "–" + clock(last)
    }
}

private struct TurnTimelineRow: View {
    var entry: TurnTimeline.Entry
    var turnModel: String?
    var includeText: Bool
    var now: Date
    var isFirst: Bool
    var isLast: Bool
    @Binding var expanded: Bool

    private static let stepLimit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard expandable else { return }
                withAnimation(BridgeTheme.reduceMotion ? nil : .easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    node.frame(width: 20)
                    line
                    Spacer(minLength: 6)
                    trailing
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(BridgeTheme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .opacity(expandable ? 1 : 0)
                }
                .padding(.leading, 10).padding(.trailing, 14)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!expandable)
            .background(failed ? BridgeTheme.danger.opacity(0.07) : Color.clear)
            .accessibilityElement(children: .combine)
            .accessibilityValue(expandable ? (expanded ? "Expanded" : "Collapsed") : "")
            if expanded, expandable {
                detail
                    .padding(.leading, 38).padding(.trailing, 14).padding(.bottom, 8)
            }
        }
        .background(alignment: .topLeading) {
            // The rail connects every row; first and last rows stop at the node.
            GeometryReader { proxy in
                Rectangle().fill(BridgeTheme.separator)
                    .frame(width: 1, height: max(0, proxy.size.height - (isFirst ? 15 : 0) - (isLast ? proxy.size.height - 15 : 0)))
                    .offset(x: 19.5, y: isFirst ? 15 : 0)
            }
        }
    }

    private var failed: Bool {
        if case let .operation(operation) = entry { return operation.outcome == .failure }
        return false
    }

    private var expandable: Bool {
        switch entry {
        case let .steps(group): return !group.steps.isEmpty
        case let .operation(operation):
            return operation.records.count > 1 || operation.records.contains { $0.preview != nil || !$0.relatedSessionIDs.isEmpty || $0.nativeID != nil }
        }
    }

    @ViewBuilder private var node: some View {
        switch entry {
        case .steps:
            Circle().strokeBorder(BridgeTheme.textTertiary, lineWidth: 1.2).frame(width: 9, height: 9)
                .background(Circle().fill(BridgeTheme.inkRaised))
        case let .operation(operation):
            let (symbol, color) = Self.symbol(operation)
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
                .frame(width: 18, height: 18)
                .background(Circle().fill(BridgeTheme.inkRaised))
        }
    }

    @ViewBuilder private var line: some View {
        switch entry {
        case let .steps(group):
            let models = group.models.filter { $0 != turnModel }
            HStack(spacing: 5) {
                Text("\(group.steps.count) model \(group.steps.count == 1 ? "step" : "steps")")
                    .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                if !models.isEmpty {
                    Text("· " + models.map(ModelNaming.display).joined(separator: ", "))
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                }
            }
            .lineLimit(1)
        case let .operation(operation):
            HStack(spacing: 6) {
                Text(Self.label(operation.kind)).font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                Text(operation.title).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .help(operation.outcome.map(\.title) ?? Self.label(operation.kind))
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 6) {
            switch entry {
            case let .steps(group):
                Text(range(group.first, group.last))
            case let .operation(operation):
                if let exit = operation.exitCode, exit != 0 {
                    Text("exit \(exit)").foregroundStyle(BridgeTheme.danger)
                }
                if let seconds = operation.durationSeconds { Text(ActivityFormat.duration(seconds)) }
                if operation.timestamp != nil { Text(clock(operation.timestamp)) }
            }
        }
        .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
        .lineLimit(1).fixedSize()
    }

    @ViewBuilder private var detail: some View {
        switch entry {
        case let .steps(group):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(group.steps.prefix(Self.stepLimit), id: \.id) { step in
                    HStack(spacing: 8) {
                        Text(clock(step.timestamp.flatMap { $0 <= now ? $0 : nil })).frame(width: 58, alignment: .leading)
                        Text(step.model.map(ModelNaming.display) ?? "Model not recorded").lineLimit(1)
                        if let effort = step.effort { Text(effort).foregroundStyle(BridgeTheme.textTertiary) }
                        Spacer(minLength: 4)
                        if let total = step.usage.total, total >= 0 {
                            Text("\(ActivityFormat.compact(total)) tokens" + (step.usage.output.flatMap { $0 >= 0 ? " · \(ActivityFormat.compact($0)) out" : nil } ?? ""))
                                .foregroundStyle(BridgeTheme.textTertiary)
                        }
                    }
                    .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary)
                    .help("Checkpoint \(step.id)")
                }
                if group.steps.count > Self.stepLimit {
                    Text("\(group.steps.count - Self.stepLimit) more in the full replay").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
            }
        case let .operation(operation):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(operation.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        if operation.records.count > 1 {
                            Text(record.kind == .toolResult ? "Result · \(record.status)" : "Call · \(record.status)")
                                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                        }
                        if includeText, let preview = record.preview {
                            ScrollView {
                                Text(preview).font(BridgeFont.mono).foregroundStyle(BridgeTheme.textSecondary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8)
                            }
                            .frame(maxHeight: 180)
                            .bridgeWell(cornerRadius: BridgeTheme.radiusWell)
                        }
                        ForEach(record.relatedSessionIDs, id: \.self) { thread in
                            Label("Handed to agent thread \(thread)", systemImage: "arrow.triangle.branch")
                                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary).textSelection(.enabled)
                        }
                        if let native = record.nativeID {
                            Text("Source \(native)").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).textSelection(.enabled)
                        }
                    }
                }
                if !includeText, operation.records.contains(where: { $0.digest != nil }) {
                    Text("Turn on Show text to read what was sent and returned.").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
            }
        }
    }

    private func clock(_ date: Date?) -> String {
        guard let date, date.timeIntervalSince1970.isFinite else { return "—" }
        return date.formatted(.dateTime.hour().minute().second())
    }

    private func range(_ first: Date?, _ last: Date?) -> String {
        guard let first else { return "time not recorded" }
        guard let last, last > first else { return clock(first) }
        return clock(first) + "–" + clock(last)
    }

    static func label(_ kind: WorkEvidenceItem.Kind) -> String {
        switch kind {
        case .request: return "Request"
        case .response: return "Reply"
        case .toolCall: return "Tool"
        case .toolResult: return "Result"
        case .fileChange: return "File change"
        case .plan: return "Plan"
        case .handoff: return "Hand-off"
        case .notice: return "Note"
        }
    }

    static func symbol(_ operation: TurnTimeline.Operation) -> (String, Color) {
        if let outcome = operation.outcome {
            switch outcome {
            case .success: return ("checkmark.circle.fill", BridgeTheme.success.opacity(0.85))
            case .failure: return ("xmark.octagon.fill", BridgeTheme.danger)
            case .interrupted: return ("pause.circle.fill", BridgeTheme.warning)
            case .unknown: return ("wrench.and.screwdriver", BridgeTheme.textSecondary)
            }
        }
        switch operation.kind {
        case .request: return ("text.bubble.fill", BridgeTheme.brand)
        case .response: return ("bubble.left.fill", BridgeTheme.textSecondary)
        case .fileChange: return ("doc.badge.gearshape", BridgeTheme.textSecondary)
        case .plan: return ("list.number", BridgeTheme.textSecondary)
        case .handoff: return ("arrow.triangle.branch", BridgeTheme.brand)
        case .notice: return ("info.circle", BridgeTheme.textTertiary)
        case .toolCall, .toolResult: return ("wrench.and.screwdriver", BridgeTheme.textSecondary)
        }
    }
}

// MARK: - Keyboard

enum DrawerKey: Equatable { case earlier, later }

enum DrawerKeyNavigation {
    static func key(code: UInt16, modifiers: NSEvent.ModifierFlags, responder: NSResponder?, hasSheet: Bool) -> DrawerKey? {
        guard !hasSheet, modifiers.intersection([.command, .option, .control, .shift, .help]).isEmpty else { return nil }
        if responder is NSText || responder is NSControl { return nil }
        var view = responder as? NSView
        while let current = view {
            if current is NSControl || current is NSText { return nil }
            view = current.superview
        }
        switch code {
        case 123: return .earlier
        case 124: return .later
        default: return nil
        }
    }
}

/// ← and → step through turns while the drawer is open, unless a text
/// field or a control that uses arrows has focus. macOS 13 has no onKeyPress.
private struct DrawerKeyMonitor: NSViewRepresentable {
    var handle: (DrawerKey) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.handle = handle
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) { view.handle = handle }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) { view.stop() }

    final class MonitorView: NSView {
        var handle: ((DrawerKey) -> Bool)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      let key = DrawerKeyNavigation.key(code: event.keyCode, modifiers: event.modifierFlags,
                                                        responder: window.firstResponder, hasSheet: window.attachedSheet != nil) else { return event }
                return self.handle?(key) == true ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
