import AppKit
import BridgeCore
import SwiftUI

/// A replay is a detail route within the common workspace. Source data is
/// frozen at entry; following later observations is a separate user choice.
struct GoalReplaySelection: Identifiable {
    let id = UUID()
    let overview: ActivityOverview
    let rootSessionID: String
    let focusSessionID: String?
    let focusTurnIDs: [String]
    init(overview: ActivityOverview, rootSessionID: String, focusSessionID: String? = nil, focusTurnIDs: [String] = []) {
        self.overview = overview; self.rootSessionID = rootSessionID; self.focusSessionID = focusSessionID
        self.focusTurnIDs = Array(focusTurnIDs.prefix(1_000))
    }
}

/// One explicit user navigation. A fresh token allows selecting the same
/// signal again to scroll back to its source without affecting follow refresh.
struct GoalReplaySignalNavigation: Equatable {
    let rowID: String
    let offset: Int
    let showOnlyErrors = false
    let requestID = UUID()

    static func make(rowID: String, index: GoalReplayIndex) -> Self? {
        guard let position = index.rows.firstIndex(where: { $0.id == rowID }) else { return nil }
        return Self(rowID: rowID, offset: (position / 100) * 100)
    }
}

/// Closing/reopening an expensive replay cannot fan out unlimited detached
/// ownership scans. A second view gets an actionable retry while one finishes.
private actor GoalReplayBuildAccess {
    static let shared = GoalReplayBuildAccess()
    private var busy = false
    func acquire() -> Bool { guard !busy else { return false }; busy = true; return true }
    func release() { busy = false }
}

@MainActor final class GoalReplayModel: ObservableObject {
    struct Prepared {
        var overview: ActivityOverview
        var index: GoalReplayIndex
        var evidenceIdentity: String
    }
    /// A single publication keeps the visible events and the source-page
    /// timestamps from the same projection, even during a refresh.
    struct IncidentProjection {
        let timeline: WorkIncidentTimeline
        let readAt: [String: Date]
        let snapshots: [String: String]
    }
    @Published private(set) var prepared: Prepared?
    @Published private(set) var preparing = false
    @Published private(set) var needsNewReplay = false
    @Published private(set) var reading = false
    @Published private(set) var batch: WorkEvidenceBatch?
    @Published private(set) var summaries: [String: WorkOutcomeSignals.Summary] = [:]
    @Published private(set) var incidentProjection: IncidentProjection?
    @Published private(set) var summaryReadAt: [String: Date] = [:]
    @Published private(set) var summarySnapshot: [String: String] = [:]
    @Published private(set) var readAt: Date?
    @Published private(set) var publication = 0
    @Published private(set) var evidencePublication = 0
    @Published private(set) var selectedSteps: [ActivityModelStep] = []
    @Published var error: String?
    @Published var selectedRowID: String?
    @Published var offset = 0
    private var summaryOrder: [String] = []
    private var pending: ActivityOverview?
    private var worker: Task<Void, Never>?
    private var signalWorker: Task<Void, Never>?
    private var pendingSignals: (Int, GoalReplayIndex, [String: WorkOutcomeSignals.Summary], [String: Date], [String: String])?
    private var signalRevision = 0
    private var active = true
    private var readGeneration = UUID()
    private let selection: GoalReplaySelection

    init(selection: GoalReplaySelection) { self.selection = selection }

    func prepare(_ overview: ActivityOverview) {
        active = true; pending = overview; preparing = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            guard await GoalReplayBuildAccess.shared.acquire() else {
                self.error = "The previous replay is still preparing. Try again in a moment."
                self.pending = nil; self.preparing = false; self.worker = nil
                return
            }
            while let input = self.pending, self.active {
                self.pending = nil
                let rootID = self.selection.rootSessionID
                let built = await Task.detached(priority: .userInitiated) {
                    let index = GoalReplayIndex.build(overview: input, rootSessionID: rootID)
                    let metadata = index.rows.map { row in
                        [row.id, row.status, String(row.modelStepCount ?? -1), String(row.toolCount ?? -1),
                         String(row.timestamp?.timeIntervalSince1970 ?? -1), row.models.joined(separator: ","), row.efforts.joined(separator: ",")].joined(separator: "|")
                    }.joined(separator: "\n")
                    return (index, TraceCrypto.digest(metadata))
                }.value
                guard self.active else { break }
                let index = built.0
                if let previous = self.prepared, previous.index.goalID != index.goalID {
                    self.needsNewReplay = true; self.pending = nil
                    self.error = "The latest snapshot no longer verifies the same goal. This inspected goal is unchanged. Open a new replay to inspect the current goal."
                    break
                }
                let firstPublication = self.prepared == nil
                if let previous = self.prepared, previous.evidenceIdentity != built.1 { self.evidencePublication += 1 }
                self.prepared = Prepared(overview: input, index: index, evidenceIdentity: built.1)
                self.publication += 1
                if self.selectedRowID.flatMap({ id in index.rows.first { $0.id == id } }) == nil {
                    let wanted = Set(self.selection.focusTurnIDs)
                    let focus = index.rows.first {
                        (self.selection.focusSessionID == nil || $0.sessionID == self.selection.focusSessionID)
                            && wanted.contains($0.nativeTurnID)
                    } ?? index.rows.first(where: { $0.sessionID == self.selection.focusSessionID }) ?? index.rows.first
                    self.selectedRowID = focus?.id
                    if firstPublication, let focus, let position = index.rows.firstIndex(where: { $0.id == focus.id }) {
                        self.offset = (position / 100) * 100
                    }
                }
                let retained = Set(index.rows.map(\.id))
                self.summaries = self.summaries.filter { retained.contains($0.key) }
                self.summaryReadAt = self.summaryReadAt.filter { retained.contains($0.key) }
                self.summarySnapshot = self.summarySnapshot.filter { retained.contains($0.key) }
                self.summaryOrder.removeAll { !retained.contains($0) }
                self.rebuildIncidentTimeline()
                self.updateSelectedSteps()
                self.offset = min(self.offset, max(0, ((index.rows.count - 1) / 100) * 100))
            }
            await GoalReplayBuildAccess.shared.release()
            self.preparing = false; self.worker = nil
            // An input can arrive while releasing the shared build lease.
            // Keep the one-worker/latest-pending guarantee at that boundary.
            if self.active, let latest = self.pending { self.prepare(latest) }
        }
    }

    func select(_ row: GoalReplayIndex.Row) {
        guard !reading, selectedRowID != row.id else { return }
        selectedRowID = row.id; clearRead(); updateSelectedSteps()
    }
    func clearRead() { readGeneration = UUID(); batch = nil; readAt = nil; error = nil }
    /// Turning off visible text also forgets all text-derived classifications.
    /// Measured, text-free tool outcomes remain available in memory.
    func forgetVisibleText() {
        clearRead()
        summaries = summaries.mapValues { $0.withoutLexicalHints() }
        // Clear immediately; an in-flight projection must not restore hints.
        incidentProjection = nil
        rebuildIncidentTimeline()
    }
    func deactivate() { active = false; pending = nil; pendingSignals = nil; signalRevision += 1; clearRead() }
    func waitUntilIdle() async { while let current = worker { await current.value } }
    func waitUntilSignalsIdle() async { while let current = signalWorker { await current.value } }

    private func updateSelectedSteps() {
        guard let prepared, let row = prepared.index.rows.first(where: { $0.id == selectedRowID }) else { selectedSteps = []; return }
        var byID: [String: ActivityModelStep] = [:]
        for step in row.sourceTurn.modelSteps ?? [] {
            if let prior = byID[step.id] { byID[step.id] = prior.merging(step) }
            else { byID[step.id] = step }
        }
        let now = prepared.overview.generatedAt
        func date(_ step: ActivityModelStep) -> Date? {
            step.timestamp.flatMap { $0.timeIntervalSince1970.isFinite && $0 <= now ? $0 : nil }
        }
        selectedSteps = byID.values.sorted {
            switch (date($0), date($1)) {
            case let (a?, b?): return a == b ? $0.id < $1.id : a < b
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return $0.id < $1.id
            }
        }
    }

    func read(row: GoalReplayIndex.Row, session: ActivitySession, turn: ActivityTurn, includeText: Bool, cursor: String? = nil) async {
        guard !reading, !AcceptanceProbe.isActive, active else { return }
        let snapshotIdentity = prepared?.evidenceIdentity
        let generation = UUID(); readGeneration = generation
        reading = true; error = nil
        defer { reading = false }
        do {
            let page = try await WorkEvidenceAccess.shared.read(session: session, turn: turn, includeText: includeText, cursor: cursor)
            guard active, readGeneration == generation, selectedRowID == row.id, !Task.isCancelled else { return }
            batch = page; let observedAt = Date(); readAt = observedAt
            let summary = WorkOutcomeSignals.summarize(page.items, isPartial: page.isPartial || page.nextCursor != nil || cursor != nil,
                includeLexicalHints: includeText, scopeID: row.provider.rawValue + ":" + row.sessionID + ":" + row.nativeTurnID)
            summaries[row.id] = summary
            summaryReadAt[row.id] = observedAt
            summarySnapshot[row.id] = snapshotIdentity
            summaryOrder.removeAll { $0 == row.id }; summaryOrder.append(row.id)
            while summaryOrder.count > 128 {
                let evicted = summaryOrder.removeFirst()
                summaries.removeValue(forKey: evicted); summaryReadAt.removeValue(forKey: evicted)
                summarySnapshot.removeValue(forKey: evicted)
            }
            rebuildIncidentTimeline()
        } catch {
            if active, readGeneration == generation { self.error = TraceRedactor.redact(error.localizedDescription, maximumCharacters: 500) }
        }
    }

    private func rebuildIncidentTimeline() {
        guard let index = prepared?.index else { incidentProjection = nil; return }
        signalRevision += 1
        pendingSignals = (signalRevision, index, summaries, summaryReadAt, summarySnapshot)
        guard signalWorker == nil else { return }
        signalWorker = Task { [weak self] in
            guard let self else { return }
            while let (revision, index, summaries, readAt, snapshots) = self.pendingSignals, self.active {
                self.pendingSignals = nil
                let result = await Task.detached(priority: .utility) {
                    WorkIncidentTimeline.build(index: index, summaries: summaries)
                }.value
                guard self.active else { break }
                if revision == self.signalRevision {
                    self.incidentProjection = IncidentProjection(timeline: result, readAt: readAt, snapshots: snapshots)
                }
            }
            self.signalWorker = nil
            if self.active, self.pendingSignals != nil { self.rebuildIncidentTimeline() }
        }
    }
}

/// Goal-wide chronology with progressively disclosed native detail. Counts of
/// successful tool executions are not a score for decisions or task quality.
struct GoalReplayView: View {
    let selection: GoalReplaySelection
    @ObservedObject var model: BridgeViewModel
    var close: () -> Void
    @StateObject private var replay: GoalReplayModel
    @State private var follow = false
    @State private var includeText = false
    @State private var checkpointLimit = 60
    @State private var checkpointsExpanded = false
    @State private var reviewSelection: WorkEvidenceSelection?
    @State private var arrivalFlash = false
    @State private var showOnlyErrors = false
    @State private var signalsExpanded = false
    @State private var showAllSignals = false
    @State private var signalLimit = 20
    @State private var signalScrollRequest: GoalReplaySignalNavigation?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(selection: GoalReplaySelection, model: BridgeViewModel, close: @escaping () -> Void) {
        self.selection = selection; self.model = model; self.close = close
        _replay = StateObject(wrappedValue: GoalReplayModel(selection: selection))
    }

    private var selectedRow: GoalReplayIndex.Row? { replay.prepared?.index.rows.first { $0.id == replay.selectedRowID } }
    private var selectedSource: (ActivitySession, ActivityTurn)? {
        guard let row = selectedRow, let overview = replay.prepared?.overview else { return nil }
        // The selected original native record is only a navigation/source
        // lookup. Replay counts come from the canonical owned index.
        let candidates = overview.sessions.filter { $0.id == row.sessionID && $0.turns.contains { $0.id == row.nativeTurnID } }
        guard let session = candidates.max(by: { $0.observedAt < $1.observedAt }) else { return nil }
        return (session, row.sourceTurn)
    }
    private var rootTitle: String {
        let snapshot = replay.prepared?.overview ?? selection.overview
        guard let root = snapshot.sessions.first(where: { $0.id == selection.rootSessionID }) else { return "Recorded work" }
        if let goal = root.goal, replay.prepared?.index.goalID == goal.id { return goal.objective }
        return root.title
    }
    private var currentSummary: WorkOutcomeSignals.Summary? { selectedRow.flatMap { replay.summaries[$0.id] } }
    private var readIdentity: String { (replay.selectedRowID ?? "none") + ":text:\(includeText)" }
    private var includeTextBinding: Binding<Bool> {
        Binding(get: { includeText }, set: { value in
            if value { replay.clearRead() } else { replay.forgetVisibleText() }
            includeText = value
        })
    }
    private var acceptanceState: [String: String] {
        ["selected": replay.selectedRowID ?? "", "offset": String(replay.offset), "follow": String(follow),
         "includeText": String(includeText), "checkpointLimit": String(checkpointLimit),
         "errorsOnly": String(showOnlyErrors),
         "signalsExpanded": String(signalsExpanded),
         "showAllSignals": String(showAllSignals), "signalLimit": String(signalLimit),
         "checkpointsExpanded": String(checkpointsExpanded), "prepared": String(replay.prepared != nil),
         "preparing": String(replay.preparing), "publication": String(replay.publication),
         "rowCount": String(replay.prepared?.index.rows.count ?? 0)]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if replay.needsNewReplay, let error = replay.error { errorView(error).padding(.horizontal, 20).padding(.bottom, 12) }
            Divider()
            if let prepared = replay.prepared {
                summary(prepared.index)
                Divider()
                HSplitView {
                    chronology(prepared)
                    detail
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if replay.preparing { ProgressView("Preparing the recorded sequence…") }
                    if let error = replay.error { errorView(error) }
                    if !replay.preparing { Button("Try again") { replay.prepare(selection.overview) }.buttonStyle(BridgeSecondaryButtonStyle(compact: true)) }
                    Spacer()
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(BridgeTheme.ink).foregroundStyle(BridgeTheme.textPrimary)
        .accessibilityIdentifier("bridge.goal-replay")
        .task { replay.prepare(selection.overview) }
        .task(id: readIdentity) {
            replay.clearRead()
            guard let row = selectedRow, let (session, turn) = selectedSource else { return }
            await replay.read(row: row, session: session, turn: turn, includeText: includeText)
        }
        .onChange(of: model.activityRevision) { _ in
            if follow, reviewSelection == nil { replay.prepare(model.activityOverview) }
        }
        .onChange(of: follow) { value in if value { replay.prepare(model.activityOverview) } }
        .onChange(of: replay.needsNewReplay) { value in if value { follow = false } }
        .onAppear { AcceptanceProbe.publish(scope: "goal-replay", state: acceptanceState) }
        .onChange(of: acceptanceState) { state in AcceptanceProbe.publish(scope: "goal-replay", state: state) }
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            guard AcceptanceProbe.isActive, AcceptanceProbe.requestScope(note) == "goal-replay" else { return }
            var supported = true
            switch AcceptanceProbe.requestName(note) {
            case "report": break
            case "exercise.safe":
                if let rows = replay.prepared?.index.rows, let row = rows.dropFirst().first ?? rows.first {
                    replay.select(row); replay.offset = rows.count > 100 ? 100 : 0
                    checkpointLimit = 120; checkpointsExpanded = true; signalsExpanded = true; follow = true
                } else { supported = false }
            case "refresh.snapshot":
                replay.prepare(replay.prepared?.overview ?? selection.overview)
            case "filter.errors": showOnlyErrors = AcceptanceProbe.requestValue(note) == "true"
            default: supported = false
            }
            AcceptanceProbe.record(note, scope: "goal-replay", state: acceptanceState, supported: supported)
        }
        .task(id: replay.evidencePublication) {
            guard replay.evidencePublication > 0, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.2)) { arrivalFlash = true }
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.5)) { arrivalFlash = false }
        }
        .onDisappear { replay.deactivate() }
        .sheet(item: $reviewSelection) { WorkEvidenceView(selection: $0) }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button(action: close) { Label("Back", systemImage: "chevron.left") }.buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                Spacer(minLength: 8)
                if replay.preparing { ProgressView().controlSize(.small).accessibilityLabel("Updating replay") }
                Button { replay.prepare(model.activityOverview) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(BridgeIconButtonStyle()).accessibilityLabel("Update replay snapshot")
                    .help("Use the newest already-observed snapshot. Does not send work to a provider.")
                Text(arrivalFlash ? "Snapshot updated" : (follow ? "Following observations" : "Inspecting snapshot"))
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.brand)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(BridgeTheme.brand.opacity(arrivalFlash ? 0.20 : 0.06), in: Capsule())
                Toggle("Follow arrivals", isOn: $follow).toggleStyle(.switch).controlSize(.small).font(BridgeFont.caption)
                    .help("Keep the sequence current without scrolling away from what you are reading. Notes always use a frozen snapshot.")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ActivityTitles.isCodexGoalWrapper(rootTitle) ? ActivityTitles.codexGoalTitle : WorkEvidencePrivacy.preview(rootTitle, maximumCharacters: 260))
                    .font(BridgeFont.secondaryMedium).lineLimit(2).help(rootTitle)
                InfoButton(title: "About this replay", text: "Read-only, in recorded order. These are saved observations, not a reconstructed private thought process. Tool detail pages are read from each session's own history when you open a turn, and may include events newer than the snapshot.")
            }
            if let at = replay.prepared?.overview.generatedAt {
                Text("Snapshot \(at.formatted(.dateTime.day().month().hour().minute().second()))")
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func summary(_ index: GoalReplayIndex) -> some View {
        let values = Array(replay.summaries.values)
        let success = values.reduce(0) { $0 + $1.successCount }
        let failed = values.reduce(0) { $0 + $1.failureCount }
        let unknown = values.reduce(0) { $0 + $1.unknownCount }
        let interrupted = values.reduce(0) { $0 + $1.interruptedCount }
        let measured = success + failed
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                metric("Recorded turns", value: String(index.summary.knownTurnCount))
                metric("Sessions", value: String(index.summary.sessionCount))
                metric("Tool runs succeeded", value: measured > 0 ? "\(Int((Double(success) / Double(measured) * 100).rounded()))% · \(success)/\(measured)" : "Not measured")
                InfoButton(title: "Tool runs succeeded", text: "Counts tool executions that reported completing, among the turns whose detail you have opened. A tool finishing is not the task succeeding or a decision being right, and an error can be an intended check.")
                Spacer(minLength: 0)
            }
            Text("Detail opened for \(values.count) of \(index.summary.indexedTurnCount) turns · \(unknown) unknown · \(interrupted) interrupted")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            DisclosureGroup(index.summary.isPartial ? "Partial history · what is missing?" : "About this sequence") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(index.summary.indexedTurnCount) indexed · \(index.summary.omittedTurnCount) outside the index limit · \(index.summary.undatedTurnCount) undated · \(index.summary.associationUncertainCount) uncertain goal links")
                    ForEach(Array(index.summary.warnings.enumerated()), id: \.offset) { _, warning in Text(warning) }
                    Text("Concurrent agents can overlap. Time order alone does not establish causality. Tools connect only through recorded IDs. Unknown outcomes are never counted as failed or successful.")
                }.font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).padding(.top, 4)
            }.font(BridgeFont.caption).foregroundStyle(index.summary.isPartial ? BridgeTheme.warning : BridgeTheme.textTertiary)
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
            Text(value).font(BridgeFont.heading.monospacedDigit())
        }
    }

    private func chronology(_ prepared: GoalReplayModel.Prepared) -> some View {
        let page = prepared.index.page(offset: replay.offset, limit: 100)
        return VStack(spacing: 0) {
            HStack {
                Text("Recorded sequence").font(BridgeFont.secondaryMedium)
                Spacer()
                Text("\(page.rows.count) of \(page.totalCount)").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            }.padding(12)
            signalNavigation(prepared)
            Toggle("Errors on this page", isOn: $showOnlyErrors).font(BridgeFont.caption).padding(.horizontal, 12).padding(.bottom, 8)
                .help("Includes native turn failures and errors in tool pages you have loaded. Unread tool outcomes remain unknown.")
            Divider()
            ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(page.rows.filter { !showOnlyErrors || knownError($0) }) { row in turnRow(row, overview: prepared.overview).id(row.id) }
                    if showOnlyErrors, !page.rows.contains(where: knownError) {
                        Text("No known errors on this page. Unread tool results have not been assessed.")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).padding(12)
                    }
                    if page.rows.isEmpty { Text("No recorded turns in this goal scope.").font(BridgeFont.secondary).padding(12) }
                }.padding(8)
            }
            .onAppear {
                guard replay.publication == 1, let selected = replay.selectedRowID else { return }
                DispatchQueue.main.async { if replay.selectedRowID == selected { reader.scrollTo(selected, anchor: .center) } }
            }
            .onChange(of: signalScrollRequest) { request in
                guard let request else { return }
                // Wait for the new page and filter state to enter the view
                // hierarchy. Snapshot refreshes do not generate this request.
                DispatchQueue.main.async {
                    guard signalScrollRequest == request, replay.offset == request.offset,
                          replay.selectedRowID == request.rowID else { return }
                    reader.scrollTo(request.rowID, anchor: .center)
                }
            }
            }
            Divider()
            HStack {
                Button { replay.offset = max(0, replay.offset - 100) } label: { Image(systemName: "chevron.left") }
                    .disabled(replay.offset == 0).accessibilityLabel("Previous 100 turns")
                Spacer()
                Text("Page \(replay.offset / 100 + 1)").font(BridgeFont.caption)
                Spacer()
                Button { if let next = page.nextOffset { replay.offset = next } } label: { Image(systemName: "chevron.right") }
                    .disabled(page.nextOffset == nil).accessibilityLabel("Next 100 turns")
            }.buttonStyle(BridgeIconButtonStyle()).padding(10)
        }.frame(minWidth: 240, idealWidth: 290, maxWidth: 350)
    }

    /// An index into pages the person has opened, not a reconstructed causal
    /// chain. Selecting an entry navigates to the originating native turn.
    private func signalNavigation(_ prepared: GoalReplayModel.Prepared) -> some View {
        DisclosureGroup(isExpanded: $signalsExpanded) {
            if let projection = replay.incidentProjection {
                let timeline = projection.timeline
                let selected = timeline.events.filter { showAllSignals || $0.kind != .toolSuccess }
                let ordered = selected.sorted { lhs, rhs in
                    switch (lhs.timestamp, rhs.timestamp) {
                    case let (a?, b?): return a == b ? lhs.id < rhs.id : a > b
                    case (_?, nil): return true
                    case (nil, _?): return false
                    case (nil, nil): return lhs.id < rhs.id
                    }
                }
                let rows = Dictionary(uniqueKeysWithValues: prepared.index.rows.map { ($0.id, $0) })
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(timeline.inspectedPageCount) \(timeline.inspectedPageCount == 1 ? "page" : "pages") opened · \(timeline.partialPageCount) partial · \(timeline.uninspectedTurnCount) \(timeline.uninspectedTurnCount == 1 ? "turn" : "turns") not represented")
                            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        InfoButton(title: "About these signals", text: "The most recently opened page for each turn is kept, up to 128 pages. Reading another page replaces the previous page for that turn. Summaries are not automatically rechecked. At the limit, review signals are kept before completed tools; newer dated items are preferred within each group and undated items fill remaining space. Order does not establish cause.")
                    }
                    Toggle("Include completed tools", isOn: $showAllSignals)
                        .font(BridgeFont.micro)
                    if ordered.isEmpty {
                        Text(timeline.inspectedPageCount == 0 ? "Open a turn to inspect its recorded tool page." : "No retained signals match this filter. Omitted signals and unread activity remain unknown.")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(ordered.prefix(signalLimit))) { event in
                                    if let id = event.rowID, let row = rows[id] {
                                        signalRow(event, row: row, prepared: prepared, projection: projection)
                                    }
                                }
                                if ordered.count > signalLimit, signalLimit < 120 {
                                    Button("Show more") { signalLimit = min(120, signalLimit + 20) }
                                        .buttonStyle(BridgeLinkButtonStyle()).font(BridgeFont.micro)
                                }
                                if ordered.count > 120 { Text("Showing up to 120 signals. Open turns for their full loaded page.").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary) }
                            }
                        }.frame(maxHeight: 190)
                    }
                    if timeline.omittedEventCount > 0 {
                        Text("\(timeline.omittedEventCount) signals not retained. Older or undated signals may be omitted; even newer completed tools may be excluded before review signals.")
                            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.top, 8)
            } else {
                Text("Preparing opened-page signals…").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).padding(.top, 8)
            }
        } label: {
            Label("Signals from opened pages", systemImage: "waveform.path")
                .font(BridgeFont.captionMedium)
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
    }

    private func signalRow(_ event: WorkIncidentTimeline.Event, row: GoalReplayIndex.Row,
                           prepared: GoalReplayModel.Prepared, projection: GoalReplayModel.IncidentProjection) -> some View {
        Button {
            guard let request = GoalReplaySignalNavigation.make(rowID: row.id, index: prepared.index) else { return }
            showOnlyErrors = request.showOnlyErrors
            replay.offset = request.offset
            replay.select(row)
            signalScrollRequest = request
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: event.kind == .toolFailure ? "exclamationmark.triangle" : "circle.dotted")
                        .foregroundStyle(event.kind == .toolFailure ? BridgeTheme.warning : BridgeTheme.textTertiary)
                    Text(event.title).font(BridgeFont.captionMedium).lineLimit(2)
                    Spacer(minLength: 0)
                }
                if let tool = event.toolName { Text(tool).font(BridgeFont.micro).lineLimit(1).foregroundStyle(BridgeTheme.textSecondary) }
                Text(event.timestamp.map { "Tool item " + $0.formatted(.dateTime.day().month().hour().minute()) } ?? "Event time not recorded")
                    .font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                if row.coverage.contains(.uncertainGoalLink) { Text("Goal link uncertain").font(BridgeFont.micro).foregroundStyle(BridgeTheme.warning) }
                if row.coverage.contains(.extendsPastGoalEnd) { Text("Turn extends past recorded goal end").font(BridgeFont.micro).foregroundStyle(BridgeTheme.warning) }
                if event.hasConflict { Text("Recorded outcomes conflict").font(BridgeFont.micro).foregroundStyle(BridgeTheme.warning) }
                if event.callNotInPage { Text("Linked call not in this page").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary) }
                if let time = projection.readAt[row.id] {
                    Text("Page opened " + time.formatted(.dateTime.day().month().hour().minute()) + (projection.snapshots[row.id] == prepared.evidenceIdentity ? "" : " · earlier snapshot"))
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(7).contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle()).disabled(replay.reading)
        .help("Open the source turn; the current native page may differ from the earlier inspected page. This signal does not establish a correction or task outcome.")
        .accessibilityLabel("\(event.title). Open its recorded turn.")
    }

    private func turnRow(_ row: GoalReplayIndex.Row, overview: ActivityOverview) -> some View {
        let session = overview.sessions.first { $0.id == row.sessionID }
        let measured = replay.summaries[row.id]
        return Button { replay.select(row) } label: {
            let status = TurnStatus(row.status, completedAt: row.sourceTurn.completedAt)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: row.sessionID == selection.rootSessionID ? "person.crop.circle" : "arrow.turn.down.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(BridgeTheme.color(for: row.provider))
                    Text(row.timestamp?.formatted(.dateTime.day().month().hour().minute().second()) ?? "Time not recorded")
                        .font(BridgeFont.captionMedium.monospacedDigit())
                    Spacer(minLength: 0)
                    Image(systemName: TurnStatusBadge.symbol(status)).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(TurnStatusBadge.color(status)).help(status.title)
                }
                Text(ActivityFormat.headline(session.map { ActivityTitles.display($0.title, provider: $0.provider, projectPath: $0.projectPath) } ?? row.sessionID, limit: 70))
                    .font(BridgeFont.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Text(modelLabel(row)).lineLimit(1)
                    if let steps = row.modelStepCount { Text("· \(steps) \(steps == 1 ? "step" : "steps")") }
                    Spacer(minLength: 2)
                    if let measured {
                        Text(rate(measured)).foregroundStyle(measured.measuredCount == 0 ? BridgeTheme.textTertiary : measured.failureCount > 0 ? BridgeTheme.warning : measured.isPartial ? BridgeTheme.brand : BridgeTheme.success)
                    }
                }.font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                .background(replay.selectedRowID == row.id ? BridgeTheme.brand.opacity(0.12) : BridgeTheme.surface,
                            in: RoundedRectangle(cornerRadius: BridgeTheme.radiusWell))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(replay.reading)
            .accessibilityAddTraits(replay.selectedRowID == row.id ? [.isSelected] : [])
            .accessibilityLabel("Inspect \(session?.title ?? "agent") · \(modelLabel(row)) · \(row.status)")
            .accessibilityIdentifier("bridge.replay.turn.\(row.id)")
    }

    private var detail: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if let row = selectedRow, let (session, turn) = selectedSource {
                    turnHeader(row, session: session, turn: turn)
                    checkpointList(turn)
                    operationList(row, session: session, turn: turn)
                } else {
                    Label("Select a recorded turn to inspect its model steps and results.", systemImage: "cursorarrow")
                        .font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).padding(.top, 20)
                }
                if let error = replay.error { errorView(error) }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minWidth: 340)
    }

    private func turnHeader(_ row: GoalReplayIndex.Row, session: ActivitySession, turn: ActivityTurn) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                SectionTitle(text: "This turn", icon: "text.bubble")
                TurnStatusBadge(status: TurnStatus(row.status, completedAt: turn.completedAt))
                Spacer(minLength: 0)
                InfoButton(title: "Turn status", text: "The provider's own status for this turn (\(row.status)). Finished means the provider stopped responding, not that the work was correct.")
            }
            Text(ActivityFormat.headline(ActivityTitles.display(session.title, provider: session.provider, projectPath: session.projectPath), limit: 180))
                .font(BridgeFont.heading).lineLimit(2).help(session.title)
            HStack(spacing: 6) {
                Text(modelLabel(row)).font(BridgeFont.secondaryMedium)
                if !row.efforts.isEmpty { Text("· " + row.efforts.joined(separator: ", ")).font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary) }
                Text("· " + (row.timestamp?.formatted(.dateTime.day().month().hour().minute().second()) ?? "Time not recorded"))
                    .font(BridgeFont.secondary.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary)
            }
            ForEach(row.coverage, id: \.rawValue) { flag in
                Label(flag.explanation, systemImage: "info.circle").font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
            }
            DisclosureGroup("Recorded connections") {
                Text(row.association.reason.replacingOccurrences(of: "_", with: " ")).font(BridgeFont.caption)
                Text("Session \(row.nativeSessionID)\nTurn \(row.nativeTurnID)\nGoal \(row.association.goalID ?? "not attributed")")
                    .font(BridgeFont.mono).textSelection(.enabled)
                ForEach(Array(row.association.evidence.enumerated()), id: \.offset) { _, evidence in
                    Text(evidence.kind.rawValue + " · " + evidence.evidenceID).font(BridgeFont.micro).textSelection(.enabled)
                }
            }.font(BridgeFont.caption)
            Button {
                guard let overview = replay.prepared?.overview else { return }
                reviewSelection = WorkEvidenceSelection(overview: overview, sessionID: session.id, turnIDs: [turn.id])
            } label: { Label("Review & next prompt", systemImage: "square.and.pencil") }
                .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                .help("Record your judgment and lessons locally. No prompt is sent and no skill is changed.")
        }.bridgeCard(padding: 14)
    }

    private func checkpointList(_ turn: ActivityTurn) -> some View {
        let steps = replay.selectedSteps
        let title = turn.modelSteps == nil ? "Model steps · not recorded" : "Model steps · \(steps.count) saved \(steps.count == 1 ? "checkpoint" : "checkpoints")"
        return DisclosureGroup(isExpanded: $checkpointsExpanded) {
            VStack(alignment: .leading, spacing: 2) {
                if steps.isEmpty { Text("No step-level detail was recorded for this turn.").font(BridgeFont.caption) }
                ForEach(Array(steps.prefix(checkpointLimit).enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: 10) {
                        Text(String(index + 1)).foregroundStyle(BridgeTheme.textTertiary).frame(width: 28, alignment: .trailing)
                        Text(validCheckpointTime(step)?.formatted(.dateTime.hour().minute().second()) ?? "—").frame(width: 64, alignment: .leading)
                        Text(step.model.map(ModelNaming.display) ?? "Model not recorded").foregroundStyle(BridgeTheme.textPrimary).lineLimit(1)
                        if let effort = step.effort { Text(effort).foregroundStyle(BridgeTheme.textTertiary) }
                        Spacer(minLength: 6)
                        Text("\(ActivityFormat.compact(step.usage.total.flatMap { $0 >= 0 ? $0 : nil })) tokens · \(ActivityFormat.compact(step.usage.output.flatMap { $0 >= 0 ? $0 : nil })) out")
                            .foregroundStyle(BridgeTheme.textTertiary)
                    }
                    .font(BridgeFont.caption.monospacedDigit()).foregroundStyle(BridgeTheme.textSecondary)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(index.isMultiple(of: 2) ? Color.white.opacity(0.025) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
                    .help("Checkpoint \(step.id) · outcome not assessed")
                    .contextMenu {
                        Button("Copy checkpoint ID") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(step.id, forType: .string)
                        }
                    }
                }
                if steps.count > checkpointLimit {
                    Button("Show 60 more model steps") { checkpointLimit += 60 }.buttonStyle(BridgeLinkButtonStyle())
                }
            }.padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text(title)
                InfoButton(title: "Model steps", text: "Observed model-usage checkpoints, not guaranteed individual API attempts. A tool is linked to a checkpoint only when the native source records that link.")
            }
        }.font(BridgeFont.secondaryMedium).bridgeCard(padding: 14)
    }

    private func operationList(_ row: GoalReplayIndex.Row, session: ActivitySession, turn: ActivityTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Requests, tools & results", icon: "point.3.connected.trianglepath.dotted")
            Toggle("Include redacted visible text", isOn: includeTextBinding).font(BridgeFont.caption).disabled(replay.reading)
            if includeText {
                Text("Local display only. Redaction is best-effort; project text may still be sensitive. Private hidden reasoning is excluded.")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
            }
            HStack {
                Button { Task { await replay.read(row: row, session: session, turn: turn, includeText: includeText) } } label: {
                    HStack { if replay.reading { ProgressView().controlSize(.small) }; Text(replay.reading ? "Reading native history…" : "Read again") }
                }.buttonStyle(BridgeSecondaryButtonStyle(compact: true)).disabled(replay.reading || AcceptanceProbe.isActive)
                Spacer()
                if let value = currentSummary { Text(rate(value)).font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.brand) }
            }
            if let value = currentSummary { outcomeSummary(value) }
            if let batch = replay.batch {
                Text(batch.message).font(BridgeFont.caption).foregroundStyle(batch.isPartial ? BridgeTheme.warning : BridgeTheme.textTertiary)
                if let readAt = replay.readAt {
                    Text("Native page read \(readAt.formatted(.dateTime.hour().minute().second())) · may include observations newer than this snapshot")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
                ForEach(batch.items) { item in operation(item) }
                if let cursor = batch.nextCursor {
                    Button("Read earlier native events") {
                        Task { await replay.read(row: row, session: session, turn: turn, includeText: includeText, cursor: cursor) }
                    }.buttonStyle(BridgeSecondaryButtonStyle(compact: true)).disabled(replay.reading)
                    Text("Earlier pages replace the current page. Percentages describe the loaded page, not the entire turn.")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
            } else if !replay.reading {
                Text(AcceptanceProbe.isActive ? "Native reads are disabled in offline UI tests." : "Select a turn or choose Read again to load its bounded native event page.")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            }
        }.bridgeCard(padding: 14)
    }

    private func outcomeSummary(_ value: WorkOutcomeSignals.Summary) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(value.successCount) succeeded · \(value.failureCount) failed · \(value.interruptedCount) interrupted · \(value.unknownCount) unknown")
                .font(BridgeFont.captionMedium)
            if value.isPartial { Text("Partial native page. Missing outcomes are excluded from the percentage.").font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning) }
            if value.conflictCount > 0 { Text("\(value.conflictCount) conflicting tool outcomes need review.").font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning) }
            if includeText, !value.hints.isEmpty {
                Text("Language signals · not verified outcomes").font(BridgeFont.captionMedium)
                ForEach(value.hints) { hint in
                    Text(hint.title).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                        .help("Heuristic \(hint.ruleID) · supporting events: \(hint.evidenceIDs.joined(separator: ", "))")
                }
            }
            HStack(spacing: 4) {
                Text(value.adapterVersion).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                InfoButton(title: "Tool outcomes", text: "Source-linked execution evidence, not a decision-quality score. A tool error can be an expected negative test or a useful experiment; review the context before judging the decision.")
            }
        }.padding(10).bridgeWell(cornerRadius: BridgeTheme.radiusWell)
    }

    private func operation(_ item: WorkEvidenceItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol(item.kind)).foregroundStyle(["failed", "error", "errored"].contains(item.status.lowercased()) ? BridgeTheme.danger : BridgeTheme.brand)
                Text(item.title).font(BridgeFont.secondaryMedium)
                Spacer(minLength: 4)
                Text(item.status).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            }
            HStack {
                if let timestamp = item.timestamp { Text(timestamp.formatted(.dateTime.hour().minute().second())) }
                else { Text("Time not recorded") }
                if let exit = item.exitCode { Text("· exit \(exit)") }
                if let seconds = item.durationSeconds { Text("· \(ActivityFormat.duration(seconds))") }
            }.font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            if let related = item.relatedID {
                Label("Recorded link: \(related)", systemImage: "link").font(BridgeFont.micro).textSelection(.enabled)
            }
            ForEach(item.relatedSessionIDs, id: \.self) { nativeID in
                Label("Linked agent thread: \(nativeID)", systemImage: "arrow.triangle.branch")
                    .font(BridgeFont.micro).textSelection(.enabled)
            }
            if includeText, let preview = item.preview {
                DisclosureGroup("Read visible text") {
                    Text(preview).font(BridgeFont.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.font(BridgeFont.caption)
            }
        }.padding(11).bridgeWell(cornerRadius: BridgeTheme.radiusWell)
    }

    private func errorView(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle").font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func rate(_ summary: WorkOutcomeSignals.Summary) -> String {
        guard let fraction = summary.successFraction else { return "Tools: not measured" }
        return "Tools \(Int((fraction * 100).rounded()))% · \(summary.successCount)/\(summary.measuredCount)\(summary.isPartial ? " · partial" : "")"
    }
    private func knownError(_ row: GoalReplayIndex.Row) -> Bool {
        ["failed", "error", "errored"].contains(row.status.lowercased()) || (replay.summaries[row.id]?.failureCount ?? 0) > 0
    }
    private func modelLabel(_ row: GoalReplayIndex.Row) -> String {
        if row.models.count > 1 { return "Mixed models · " + row.models.map(ModelNaming.display).joined(separator: ", ") }
        return row.model.map(ModelNaming.display) ?? "Model not recorded"
    }
    private func validCheckpointTime(_ step: ActivityModelStep) -> Date? {
        guard let date = step.timestamp, date.timeIntervalSince1970.isFinite,
              date <= (replay.prepared?.overview.generatedAt ?? selection.overview.generatedAt) else { return nil }
        return date
    }
    private func symbol(_ kind: WorkEvidenceItem.Kind) -> String {
        switch kind {
        case .request: return "text.bubble"
        case .response: return "bubble.left"
        case .toolCall: return "wrench.and.screwdriver"
        case .toolResult: return "checklist"
        case .fileChange: return "doc.badge.gearshape"
        case .plan: return "list.number"
        case .handoff: return "arrow.triangle.branch"
        case .notice: return "info.circle"
        }
    }
}
