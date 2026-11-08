import AppKit
import BridgeCore
import SwiftUI

/// Frozen at the intentional inspection action. Refreshes cannot change the
/// evidence underneath a note the person is writing.
struct WorkEvidenceSelection: Identifiable {
    let id = UUID()
    let overview: ActivityOverview
    let sessionID: String
    let turnIDs: [String]
    let requestedCount: Int
    init(overview: ActivityOverview, sessionID: String, turnIDs: [String]) {
        self.overview = overview; self.sessionID = sessionID
        self.turnIDs = Array(turnIDs.prefix(160)); requestedCount = turnIDs.count
    }
}

/// All detail windows share a single bounded reader, including a request
/// whose sheet was closed before the provider answered. Never fan out CLIs.
actor WorkEvidenceAccess {
    static let shared = WorkEvidenceAccess()
    private var busy = false
    /// Lets a caller wait for a finishing read instead of reporting an error.
    var isBusy: Bool { busy }
    func read(session: ActivitySession, turn: ActivityTurn, includeText: Bool, cursor: String?) async throws -> WorkEvidenceBatch {
        guard !busy else { throw BridgeError.invalidRequest("An evidence read is finishing. Try again in a moment.") }
        busy = true; defer { busy = false }
        let configuration = try ConfigurationStore.load(create: false)
        return try await WorkEvidenceReader.read(session: session, turn: turn, configuration: configuration.agents, includeText: includeText, cursor: cursor)
    }
}

@MainActor private final class WorkEvidenceModel: ObservableObject {
    @Published var batch: WorkEvidenceBatch?
    @Published var busy = false
    @Published var saving = false
    @Published var error: String?
    @Published var saved = false
    @Published var reviews: [WorkReflectionRecord] = []
    @Published var readAt: Date?
    private let store = WorkReflectionStore()
    private var generation = UUID()

    func clear() { generation = UUID(); batch = nil; readAt = nil; error = nil; saved = false }
    func load(session: ActivitySession, turn: ActivityTurn, includeText: Bool, cursor: String? = nil) async {
        guard !busy, !AcceptanceProbe.isActive else { return }
        let token = UUID(); generation = token; busy = true; error = nil
        defer { busy = false }
        do {
            let result = try await WorkEvidenceAccess.shared.read(session: session, turn: turn, includeText: includeText, cursor: cursor)
            guard generation == token, !Task.isCancelled else { return }
            batch = result; readAt = Date()
        } catch { if generation == token { self.error = TraceRedactor.redact(error.localizedDescription, maximumCharacters: 500) } }
    }
    func loadReviews(sessionID: String) async {
        guard !AcceptanceProbe.isActive else { return }
        do { reviews = try await store.load(limit: 200).filter { $0.draft.evidence.contains { $0.sessionID == sessionID } } }
        catch { self.error = error.localizedDescription }
    }
    func save(_ draft: WorkReflectionDraft, sessionID: String) async {
        guard !saving, !AcceptanceProbe.isActive else { return }
        let token = generation
        saving = true; error = nil; saved = false
        defer { saving = false }
        do {
            _ = try await store.append(draft)
            guard generation == token, !Task.isCancelled else { return }
            saved = true; await loadReviews(sessionID: sessionID)
        } catch { if generation == token { self.error = error.localizedDescription } }
    }
}

/// Read-only history and personal reflection, not an agent control surface.
struct WorkEvidenceView: View {
    let selection: WorkEvidenceSelection
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = WorkEvidenceModel()
    @State private var selectedTurnID: String
    @State private var includeText = false
    @State private var outcome = WorkReflectionOutcome.unknown
    @State private var rating = 0
    @State private var issue = ""
    @State private var note = ""
    @State private var nextPrompt = ""
    @State private var selectedItem: WorkEvidenceItem?
    private let session: ActivitySession?
    private let turns: [ActivityTurn]
    private let sessionAssociations: [String: GoalWorkMapping.Association]

    init(selection: WorkEvidenceSelection) {
        self.selection = selection
        session = selection.overview.sessions.first { $0.id == selection.sessionID }
        sessionAssociations = GoalWorkMapping.resolve(sessions: selection.overview.sessions, now: selection.overview.generatedAt)
        let wanted = Set(selection.turnIDs)
        let owned = ActivityAnalytics.ownedTurnsBySession(in: selection.overview.sessions)[selection.sessionID] ?? []
        turns = owned.filter { wanted.contains($0.id) }.sorted {
            let a = $0.startedAt ?? $0.completedAt ?? .distantPast
            let b = $1.startedAt ?? $1.completedAt ?? .distantPast
            return a == b ? $0.id < $1.id : a < b
        }
        _selectedTurnID = State(initialValue: turns.first?.id ?? "")
    }
    private var turn: ActivityTurn? { turns.first { $0.id == selectedTurnID } }
    private var association: GoalWorkMapping.Association? {
        guard let session, let turn else { return nil }
        return GoalWorkMapping.association(for: turn, sessionID: session.id, sessions: selection.overview.sessions,
                                          now: selection.overview.generatedAt, at: selectedItem?.timestamp,
                                          sessionAssociation: sessionAssociations[session.id])
    }
    private var goal: ActivityGoal? {
        guard let association, association.state == .matched, let id = association.goalID else { return nil }
        return selection.overview.goals.first { $0.id == id }
    }
    private var evidence: WorkReflectionEvidence? {
        guard let session, let turn else { return nil }
        return .init(provider: session.provider, sessionID: session.id, goalID: goal?.id,
                     nativeSessionID: session.nativeID, nativeTurnID: turn.id,
                     toolCallID: selectedItem?.kind == .toolCall ? selectedItem?.nativeID : (selectedItem?.kind == .toolResult ? selectedItem?.relatedID : nil),
                     stageID: selectedItem?.id ?? turn.id, payloadDigest: selectedItem?.digest,
                     snapshotAsOf: selection.overview.generatedAt)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("What happened here").font(BridgeFont.heading)
                    Text(session?.title ?? "Session unavailable").font(BridgeFont.secondary).foregroundStyle(BridgeTheme.textSecondary).lineLimit(2)
                    Text("Snapshot \(selection.overview.generatedAt.formatted(.dateTime.day().month().hour().minute())) · read-only")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(BridgeIconButtonStyle())
                    .keyboardShortcut(.cancelAction).accessibilityLabel("Close evidence")
            }.padding(20)
            Divider()
            HSplitView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Recorded sequence", systemImage: "list.number").font(BridgeFont.secondaryMedium)
                        if let goal { Text("Goal: \(goal.objective)").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).lineLimit(3) }
                        Text("Order is chronological, not proof that one step caused another. Parent/goal links require recorded identities.")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                        if selection.requestedCount > selection.turnIDs.count {
                            Text("Showing the first \(selection.turnIDs.count) of \(selection.requestedCount) selected records.").font(BridgeFont.caption)
                        }
                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, value in
                            Button {
                                guard !model.busy, !model.saving else { return }
                                selectedTurnID = value.id; selectedItem = nil; model.clear()
                                rating = 0; outcome = .unknown; issue = ""; note = ""; nextPrompt = ""
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack {
                                        Text("\(index + 1). \(value.startedAt?.formatted(.dateTime.hour().minute().second()) ?? "Time not recorded")")
                                        Spacer(); Text(value.status).foregroundStyle(isFailure(value.status) ? BridgeTheme.danger : BridgeTheme.textTertiary)
                                    }.font(BridgeFont.captionMedium)
                                    Text(value.model.map(ModelNaming.display) ?? "Model not recorded").font(BridgeFont.secondary)
                                    Text("\(nonnegative(value.toolCount).map(String.init) ?? "—") tool calls · \(value.modelSteps.map { String($0.count) } ?? "—") saved checkpoints")
                                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                                }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedTurnID == value.id ? BridgeTheme.brand.opacity(0.10) : BridgeTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).disabled(model.busy || model.saving)
                        }
                        if turns.isEmpty { Text("No owned records were found in this snapshot. No history was guessed.").font(BridgeFont.secondary) }
                    }.padding(16)
                }.frame(minWidth: 250, idealWidth: 300, maxWidth: 340)
                ScrollView {
                    if let session, let turn {
                        VStack(alignment: .leading, spacing: 18) {
                            recordSummary(session, turn)
                            evidenceTrail(session, turn)
                            reflectionForm(session, turn)
                            recentNotes(turn)
                            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning) }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(minWidth: 420)
            }
        }
        .frame(minWidth: 820, idealWidth: 1060, minHeight: 560, idealHeight: 720)
        .background(BridgeTheme.ink).foregroundStyle(BridgeTheme.textPrimary).preferredColorScheme(.dark)
        .task { if let session { await model.loadReviews(sessionID: session.id) } }
        .onDisappear { model.clear() }
        .onChange(of: includeText) { enabled in if !enabled { selectedItem = nil; model.clear() } }
        .onChange(of: note) { _ in model.saved = false }
        .onChange(of: nextPrompt) { _ in model.saved = false }
        .onChange(of: rating) { _ in model.saved = false }
        .onChange(of: outcome) { _ in model.saved = false }
        .onChange(of: issue) { _ in model.saved = false }
        .accessibilityIdentifier("bridge.work-evidence")
    }

    private func recordSummary(_ session: ActivitySession, _ turn: ActivityTurn) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionTitle(text: "Recorded facts", icon: "doc.text.magnifyingglass")
            HStack { Tag(text: turn.status); Text(turn.model.map(ModelNaming.display) ?? "Model not recorded"); Spacer() }.font(BridgeFont.secondary)
            if isFailure(turn.status) {
                Label("The native record reports a failure or interruption. That does not establish its root cause.", systemImage: "exclamationmark.triangle")
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
            }
            Text("Native turn pool: \(ActivityFormat.compact(nonnegative(turn.usage.total))) tokens · \(nonnegative(turn.toolCount).map(String.init) ?? "—") recorded tools")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            Text("Native turn pools can span many model steps and are not the filtered dashboard total.")
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            if !turn.categories.isEmpty {
                Text(turn.categories.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: " · "))
                    .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            }
            ForEach(turn.artifacts.prefix(8)) { artifact in
                Label(WorkEvidencePrivacy.preview(artifact.path, maximumCharacters: 200), systemImage: "doc")
                    .font(BridgeFont.caption).textSelection(.enabled)
            }
            DisclosureGroup("Source identifiers") {
                Text("Session \(session.nativeID)\nNative record \(turn.id)\nGoal \(goal?.id ?? "not attributed")")
                    .font(BridgeFont.mono).textSelection(.enabled)
                Button("Copy native session ID") { ActivityDisplay.copy(session.nativeID) }
                    .buttonStyle(BridgeLinkButtonStyle()).font(BridgeFont.caption)
            }.font(BridgeFont.caption)
            if let association {
                DisclosureGroup("How this connects") {
                    Text(association.reason.replacingOccurrences(of: "_", with: " ")).font(BridgeFont.caption)
                    ForEach(Array(association.evidence.enumerated()), id: \.offset) { _, link in
                        Text("\(link.kind.rawValue): \(link.sourceSessionID) → \(link.targetSessionID ?? link.goalID ?? "recorded evidence")")
                            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).textSelection(.enabled)
                    }
                    if association.state != .matched {
                        Text("A current goal is not assigned to old work just because it used the same project or session.")
                            .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
                    }
                }.font(BridgeFont.caption)
            }
        }.bridgeCard(padding: 14)
    }

    private func evidenceTrail(_ session: ActivitySession, _ turn: ActivityTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Requests, actions & results", icon: "point.3.connected.trianglepath.dotted")
            Text("Read persisted native history on demand. This does not resume a conversation or run a model. Only visible plans/explanations are eligible; private hidden reasoning is excluded.")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            Toggle("Include redacted request, response and tool text", isOn: $includeText).font(BridgeFont.caption).disabled(model.busy)
            if includeText { Text("Text can contain project secrets. Redaction is best-effort. Previews stay in memory and are not sent or saved.").font(BridgeFont.micro).foregroundStyle(BridgeTheme.warning) }
            Button { Task { await model.load(session: session, turn: turn, includeText: includeText) } } label: {
                HStack { if model.busy { ProgressView().controlSize(.small) }; Text(model.batch == nil ? "Read local evidence" : "Read again") }
            }.buttonStyle(BridgeSecondaryButtonStyle(compact: true)).disabled(model.busy || AcceptanceProbe.isActive)
            if let batch = model.batch {
                Text(batch.message).font(BridgeFont.caption).foregroundStyle(batch.isPartial ? BridgeTheme.warning : BridgeTheme.textTertiary)
                if let readAt = model.readAt {
                    Text("History read \(readAt.formatted(.dateTime.hour().minute().second())). This page may contain events newer than the frozen snapshot above.")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                }
                ForEach(batch.items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Image(systemName: symbol(item.kind)).foregroundStyle(isFailure(item.status) ? BridgeTheme.danger : BridgeTheme.brand)
                            Text(item.title).font(BridgeFont.secondaryMedium)
                            Spacer(); Text(item.status).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                        }
                        if let code = item.exitCode { Text("Exit code \(code)").font(BridgeFont.micro.monospacedDigit()) }
                        if let time = item.timestamp { Text(time.formatted(.dateTime.day().month().hour().minute().second())).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary) }
                        if let related = item.relatedID { Text("Linked to \(related)").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).textSelection(.enabled) }
                        if includeText, let preview = item.preview {
                            DisclosureGroup("Read visible text") { Text(preview).font(BridgeFont.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .font(BridgeFont.caption)
                        }
                        Button("Note this event") { selectedItem = item; model.saved = false }
                            .font(BridgeFont.caption).buttonStyle(BridgeLinkButtonStyle()).disabled(model.saving)
                    }.padding(10).bridgeWell(cornerRadius: 8)
                }
                if let cursor = batch.nextCursor {
                    Button("Earlier events") { Task { await model.load(session: session, turn: turn, includeText: includeText, cursor: cursor) } }
                        .buttonStyle(BridgeSecondaryButtonStyle(compact: true)).disabled(model.busy)
                }
                Text("Adapter \(batch.adapterVersion) · no raw payloads persisted").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            }
        }.bridgeCard(padding: 14)
    }

    private func reflectionForm(_ session: ActivitySession, _ turn: ActivityTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Notes for your next prompt", icon: "square.and.pencil")
            Text("Your judgment, not an automatic quality score. Tokens and activity volume do not prove progress.")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            if let selectedItem {
                HStack {
                    Text("Reviewing: \(selectedItem.title)").font(BridgeFont.caption).foregroundStyle(BridgeTheme.brand)
                    Button("Whole native record instead") { self.selectedItem = nil; model.saved = false }.font(BridgeFont.caption).buttonStyle(.plain)
                }
            }
            HStack {
                Picker("Outcome", selection: $outcome) {
                    Text("Not assessed").tag(WorkReflectionOutcome.unknown); Text("Useful").tag(WorkReflectionOutcome.useful)
                    Text("Partial").tag(WorkReflectionOutcome.partial); Text("Blocked").tag(WorkReflectionOutcome.blocked)
                }
                Picker("Usefulness", selection: $rating) {
                    Text("Not rated").tag(0)
                    ForEach(1...5, id: \.self) { Text("\($0) / 5").tag($0) }
                }
            }.font(BridgeFont.caption)
            Picker("What needs attention?", selection: $issue) {
                Text("No issue selected").tag("")
                ForEach(WorkReflectionIssue.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
            }.font(BridgeFont.caption)
            TextField("What helped, failed or needs clarification?", text: $note, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5).disabled(model.saving)
            TextField("What will you ask or clarify next?", text: $nextPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5).disabled(model.saving)
            Text("\(noteForStorage.count) / 1,200 characters for the saved note")
                .font(BridgeFont.micro).foregroundStyle(noteForStorage.count > 1_200 ? BridgeTheme.warning : BridgeTheme.textTertiary)
            HStack {
                Button("Save local note") {
                    guard let evidence else { return }
                    let text = noteForStorage
                    let draft = WorkReflectionDraft(evidence: [evidence], outcome: outcome, rating: rating == 0 ? nil : rating,
                        issue: WorkReflectionIssue(rawValue: issue), note: text.isEmpty ? nil : text, rubricVersion: "personal-usefulness/1")
                    Task { await model.save(draft, sessionID: session.id) }
                }.buttonStyle(BridgeSecondaryButtonStyle(compact: true)).disabled(model.saving || model.saved || noteForStorage.count > 1_200 || AcceptanceProbe.isActive || (note.isEmpty && nextPrompt.isEmpty && rating == 0 && outcome == .unknown && issue.isEmpty))
                if model.saved { Label("Saved on this Mac", systemImage: "checkmark.circle").font(BridgeFont.caption).foregroundStyle(BridgeTheme.success) }
                Spacer()
                Button("Copy next prompt") { ActivityDisplay.copy(nextPrompt) }.buttonStyle(BridgeLinkButtonStyle()).disabled(nextPrompt.isEmpty)
            }
            Text("No prompt is sent. No skill, provider setting or running goal is changed. Notes reference this native record; they do not copy its transcript.")
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
        }.bridgeCard(padding: 14)
            .disabled(model.saving)
    }

    @ViewBuilder private func recentNotes(_ turn: ActivityTurn) -> some View {
        let records = model.reviews.filter { $0.draft.evidence.contains { $0.nativeTurnID == turn.id } }
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Your recent notes", icon: "clock.arrow.circlepath")
                ForEach(records.prefix(12)) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(record.createdAt.formatted(.dateTime.day().month().hour().minute())) · \(record.draft.outcome.rawValue) · \(record.draft.rating.map { "\($0)/5" } ?? "not rated")").font(BridgeFont.captionMedium)
                        if let issue = record.draft.issue { Text(issue.title).font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning) }
                        if let note = record.draft.note { Text(note).font(BridgeFont.secondary).textSelection(.enabled) }
                    }.padding(10).bridgeWell(cornerRadius: 8)
                }
                Text("Showing matches within the 200 most recent local reviews.").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            }.bridgeCard(padding: 14)
        }
    }
    private func isFailure(_ value: String) -> Bool { ["failed", "error", "errored", "interrupted", "canceled"].contains(value.lowercased()) }
    private func nonnegative(_ value: Int?) -> Int? { value.flatMap { $0 >= 0 ? $0 : nil } }
    private var noteForStorage: String {
        [note.isEmpty ? nil : note, nextPrompt.isEmpty ? nil : "Next prompt: " + nextPrompt].compactMap { $0 }.joined(separator: "\n")
    }
    private func symbol(_ kind: WorkEvidenceItem.Kind) -> String {
        switch kind { case .request: "text.bubble"; case .response: "bubble.left"; case .toolCall: "wrench.and.screwdriver"; case .toolResult: "checklist"; case .fileChange: "doc.badge.gearshape"; case .plan: "list.number"; case .handoff: "arrow.triangle.branch"; case .notice: "info.circle" }
    }
}
