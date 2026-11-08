import AppKit
import BridgeCore
import SwiftUI

struct JEVToolPageGroup: Identifiable, Sendable {
    let id: String
    let receipts: [JEVToolPageAssessment]
    var first: JEVToolPageAssessment { receipts[0] }
    /// A flag is an imported model opinion about a listed exit, not a verified
    /// failure. Keep all opinions, including dissent, for the same capture.
    var exitFlagged: Bool { receipts.contains { $0.answers.listedNonzeroExit == .yes } }
    var exitOpinionsDiffer: Bool { Set(receipts.map(\.answers.listedNonzeroExit)).count > 1 }
    static func build(_ receipts: [JEVToolPageAssessment], sessionIDs: Set<String>) -> [Self] {
        let selected = receipts.filter { sessionIDs.contains($0.sessionID) }
        let groups = Dictionary(grouping: selected) { "\($0.evidenceID)|\($0.stateHash)|\($0.rubricHash)|\($0.captureID)" }
        return groups.map { key, values in
            Self(id: key, receipts: values.sorted { ($0.assessedAt ?? .distantPast) == ($1.assessedAt ?? .distantPast) ? $0.id < $1.id : ($0.assessedAt ?? .distantPast) > ($1.assessedAt ?? .distantPast) })
        }.sorted {
            if $0.exitFlagged != $1.exitFlagged { return $0.exitFlagged }
            return ($0.first.assessedAt ?? .distantPast) == ($1.first.assessedAt ?? .distantPast) ? $0.id < $1.id : ($0.first.assessedAt ?? .distantPast) > ($1.first.assessedAt ?? .distantPast)
        }
    }
}

/// Typed components prevent session IDs containing separators from causing a
/// different selection to reuse the same SwiftUI task identity.
struct JEVInsightsScopeKey: Equatable {
    let revision: UInt64
    let generatedAt: Date
    let sessionIDs: [String]
    init(revision: UInt64, generatedAt: Date, sessionIDs: [String]) {
        self.revision = revision; self.generatedAt = generatedAt
        self.sessionIDs = Array(Set(sessionIDs)).sorted()
    }
}

/// Historical opinions and their allowed navigation identities are published
/// as one value. A navigable identity does not establish source freshness.
struct JEVHistoricalData: Sendable {
    let pages: [JEVToolPageGroup]
    let summary: JEVHistoricalToolSummary
    let navigableEvidenceIDs: Set<String>

    static func navigableIDs(receipts: [JEVToolPageAssessment], sessionIDs: Set<String>,
                             currentDigests: [String: String]) -> Set<String> {
        Set(receipts.filter { sessionIDs.contains($0.sessionID) && (try? $0.validate()) != nil }.map(\.evidenceID))
            .intersection(currentDigests.keys)
    }
}

/// Optional, explicitly imported observations. No network calls are made by
/// opening the dashboard. Keep the prior view during refresh or import.
@MainActor
final class JEVInsightsModel: ObservableObject {
    /// Injectable operations let tests deterministically exercise a filter
    /// change while a private import or a background read is still in flight.
    struct Operations: Sendable {
        var load: @Sendable (ActivityOverview, Set<String>) async -> (JEVAssessmentDisplay?, JEVHistoricalData?)
        var importMetadata: @Sendable (URL) async throws -> Int
        var importToolPages: @Sendable (URL) async throws -> Int
    }
    @Published private(set) var display: JEVAssessmentDisplay?
    @Published private(set) var historical: JEVHistoricalData?
    var toolPages: [JEVToolPageGroup] { historical?.pages ?? [] }
    @Published private(set) var message: String?
    @Published private(set) var metadataReadFailed = false
    @Published private(set) var toolReadFailed = false
    @Published private(set) var metadataSnapshotKey: JEVInsightsScopeKey?
    @Published private(set) var historicalSnapshotKey: JEVInsightsScopeKey?
    @Published private(set) var busy = false
    @Published private(set) var loading = false
    private var task: Task<Void, Never>?
    private var worker: Task<(JEVAssessmentDisplay?, JEVHistoricalData?), Never>?
    private var revision = 0
    private var latestInput: (overview: ActivityOverview, sessionIDs: Set<String>, snapshotRevision: UInt64)?
    private let operations: Operations
    private static var directory: URL { BridgePaths.applicationSupport.appendingPathComponent("JEVAssessments", isDirectory: true) }
    private static var toolDirectory: URL { BridgePaths.applicationSupport.appendingPathComponent("JEVToolPageAssessments", isDirectory: true) }

    init(operations: Operations? = nil) { self.operations = operations ?? Self.liveOperations() }

    private static func liveOperations() -> Operations {
        let directory = Self.directory, toolDirectory = Self.toolDirectory
        return Operations(load: { overview, sessionIDs in
            var metadataRecords: [JEVAssessmentReceipt]?, toolRecords: [JEVToolPageAssessment]?
            do {
                if FileManager.default.fileExists(atPath: directory.path) { metadataRecords = try await JEVAssessmentStore(directory: directory).list() } else { metadataRecords = [] }
            } catch { metadataRecords = nil }
            do {
                if FileManager.default.fileExists(atPath: toolDirectory.path) { toolRecords = try await JEVToolPageAssessmentStore(directory: toolDirectory).list() } else { toolRecords = [] }
            } catch { toolRecords = nil }
            // Compute identity consistency once for both stores. Restrict to
            // selected imported references; never infer that a historical page
            // is current merely because its local identity is navigable.
            let relevantMetadata = (metadataRecords ?? []).filter { sessionIDs.contains($0.sessionID) }
            let relevantTools = (toolRecords ?? []).filter { sessionIDs.contains($0.sessionID) }
            let referencedIDs = Set(relevantMetadata.map(\.evidenceID)).union(relevantTools.map(\.evidenceID))
            let digests = JEVAssessmentEvidence.currentDigests(overview: overview, restrictingTo: referencedIDs)
            let metadata = metadataRecords.map { JEVAssessmentDisplay.build(receipts: $0, currentDigests: digests, sessionIDs: sessionIDs) }
            let historical = toolRecords.map { records in
                JEVHistoricalData(pages: JEVToolPageGroup.build(records, sessionIDs: sessionIDs),
                                  summary: JEVHistoricalToolSummary.build(receipts: records, sessionIDs: sessionIDs),
                                  navigableEvidenceIDs: JEVHistoricalData.navigableIDs(receipts: records, sessionIDs: sessionIDs, currentDigests: digests))
            }
            return (metadata, historical)
        }, importMetadata: { url in
            try await JEVAssessmentStore(directory: directory).importJSONL(at: url)
        }, importToolPages: { url in
            try await JEVToolPageAssessmentStore(directory: toolDirectory).importJSONL(at: url)
        })
    }

    /// A date-range change does not itself change the scope: these assessments
    /// intentionally describe all saved turns in the selected sessions.
    func matchesScope(_ sessionIDs: Set<String>) -> Bool { latestInput?.sessionIDs == sessionIDs }

    func matchesRequest(_ key: JEVInsightsScopeKey) -> Bool {
        guard let input = latestInput else { return false }
        return key == JEVInsightsScopeKey(revision: input.snapshotRevision, generatedAt: input.overview.generatedAt,
                                          sessionIDs: Array(input.sessionIDs))
    }

    /// The user's view may change before its .task runs. Never navigate using
    /// identities checked against a previous snapshot or a failed read.
    func canInspectMetadata(for key: JEVInsightsScopeKey) -> Bool {
        !loading && !metadataReadFailed && display != nil && metadataSnapshotKey == key && matchesRequest(key)
    }
    func canInspectHistorical(for key: JEVInsightsScopeKey) -> Bool {
        !loading && !toolReadFailed && historical != nil && historicalSnapshotKey == key && matchesRequest(key)
    }
    func hasPreviousResults(for key: JEVInsightsScopeKey) -> Bool {
        (display != nil && metadataSnapshotKey != key) || (historical != nil && historicalSnapshotKey != key)
    }

    @discardableResult func load(overview: ActivityOverview, sessionIDs: Set<String>, snapshotRevision: UInt64 = 0) -> Task<Void, Never> {
        let changedScope = !matchesScope(sessionIDs)
        let key = JEVInsightsScopeKey(revision: snapshotRevision, generatedAt: overview.generatedAt, sessionIDs: Array(sessionIDs))
        latestInput = (overview, sessionIDs, snapshotRevision)
        revision += 1; let requested = revision
        task?.cancel(); worker?.cancel()
        if changedScope {
            display = nil; historical = nil
            metadataSnapshotKey = nil; historicalSnapshotKey = nil
            metadataReadFailed = false; toolReadFailed = false; message = nil
        }
        loading = true
        let operations = self.operations
        let work = Task.detached(priority: .utility) { await operations.load(overview, sessionIDs) }
        worker = work
        let observer = Task {
            let outcome = await work.value
            guard !Task.isCancelled, requested == revision else { return }
            metadataReadFailed = outcome.0 == nil; toolReadFailed = outcome.1 == nil
            if let value = outcome.0 { display = value; metadataSnapshotKey = key }
            if let value = outcome.1 { historical = value; historicalSnapshotKey = key }
            loading = false
        }
        task = observer
        return observer
    }

    func waitUntilIdle() async { await task?.value }

    /// Imports are global to the app-owned store. Reload the *current* scope
    /// after the write, never the filter captured when the panel was opened.
    func importFile(_ url: URL, historical: Bool) async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            if historical { _ = try await operations.importToolPages(url) }
            else { _ = try await operations.importMetadata(url) }
            if let input = latestInput { load(overview: input.overview, sessionIDs: input.sessionIDs, snapshotRevision: input.snapshotRevision) }
        } catch {
            message = "Import may be incomplete. Check the format, ownership and 0600 permissions; existing assessments were retained."
        }
    }

    func chooseImport(overview: ActivityOverview, sessionIDs: Set<String>, snapshotRevision: UInt64) {
        let key = JEVInsightsScopeKey(revision: snapshotRevision, generatedAt: overview.generatedAt, sessionIDs: Array(sessionIDs))
        if !matchesRequest(key) { load(overview: overview, sessionIDs: sessionIDs, snapshotRevision: snapshotRevision) }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = "Choose an owner-only JEV assessment JSONL file. No data is sent online."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importFile(url, historical: false) }
    }

    func chooseToolImport(overview: ActivityOverview, sessionIDs: Set<String>, snapshotRevision: UInt64) {
        let key = JEVInsightsScopeKey(revision: snapshotRevision, generatedAt: overview.generatedAt, sessionIDs: Array(sessionIDs))
        if !matchesRequest(key) { load(overview: overview, sessionIDs: sessionIDs, snapshotRevision: snapshotRevision) }
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.message = "Choose an owner-only historical tool-page JSONL file. No data is sent online."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importFile(url, historical: true) }
    }
}

struct JEVInsightsCard: View {
    let overview: ActivityOverview
    let sessionIDs: [String]
    let snapshotRevision: UInt64
    let inspect: (String, String?) -> Void
    @StateObject private var model = JEVInsightsModel()
    @State private var historicalExpanded = false
    private var key: JEVInsightsScopeKey { JEVInsightsScopeKey(revision: snapshotRevision, generatedAt: overview.generatedAt, sessionIDs: sessionIDs) }
    private var inCurrentScope: Bool { model.matchesScope(Set(sessionIDs)) }
    private func opinion(_ a: JEVToolPageAssessment.Answers) -> String {
        "Listed nonzero exit: \(a.listedNonzeroExit.rawValue) · Listed completed tool: \(a.listedCompletedTool.rawValue) · Artifact recorded: \(a.artifactRecorded.rawValue) · Recorded goal status completed: \(a.goalStatusRecordedCompleted.rawValue) · Listed duration missing: \(a.listedMissingDuration.rawValue) · Models recorded: \(a.recordedModelsPresent.rawValue) · Turn elapsed time missing: \(a.turnElapsedMissing.rawValue)"
    }
    private func hasTurn(_ item: JEVToolPageAssessment) -> Bool {
        model.canInspectHistorical(for: key) && model.historical?.navigableEvidenceIDs.contains(item.evidenceID) == true
    }

    private static let explanation = "Optional JEV assessments interpret allowlisted session metadata. These are model opinions, not measured token counts, tool outcomes, verified completions or a success rate. One evidence item is counted once even when several models assess it. Different labels include one model saying unknown; conflicting categories require two different specific labels. Different inputs, providers or rubric versions, and conflicting same-time attempts, are incomparable. Only the latest assessment per model is displayed. Stale and unavailable evidence is excluded. Assessments span all saved turns in the selected sessions; the report's date filter does not limit this card. No data is sent online when this view opens."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if inCurrentScope && (model.display != nil || model.historical != nil) && (model.loading || model.hasPreviousResults(for: key)) {
                Label(model.loading ? "Updating · showing previous results for this selection" : "Showing previous results · current snapshot not checked",
                      systemImage: model.loading ? "arrow.triangle.2.circlepath" : "clock.arrow.circlepath")
                    .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).labelStyle(CompactLabelStyle())
            }
            if inCurrentScope, let message = model.message {
                CalloutBanner(tone: .warning, title: message, compact: true)
            }
            if inCurrentScope && model.metadataReadFailed {
                CalloutBanner(tone: .warning, title: "Saved metadata assessments could not be read",
                              detail: "Previous results for this selection are shown if available; activity figures are unchanged.", compact: true)
            }
            metadataSection
            historicalSection
        }
        .bridgeCard(padding: 16)
        .task(id: key) { model.load(overview: overview, sessionIDs: Set(sessionIDs), snapshotRevision: snapshotRevision) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(BridgeTheme.brand)
                .frame(width: 26, height: 26).background(BridgeTheme.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Work signals").font(BridgeFont.heading).foregroundStyle(BridgeTheme.textPrimary)
                        .accessibilityIdentifier("bridge.jev.insights")
                    InfoButton(title: "Work signals", text: Self.explanation)
                        .accessibilityIdentifier("bridge.jev.info")
                }
                Text(subtitle).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Import assessments…") { model.chooseImport(overview: overview, sessionIDs: Set(sessionIDs), snapshotRevision: snapshotRevision) }
                    .help("Import a private local assessment file; no model call is made")
                    .accessibilityIdentifier("bridge.jev.import")
                Button("Import historical tool pages…") { model.chooseToolImport(overview: overview, sessionIDs: Set(sessionIDs), snapshotRevision: snapshotRevision) }
                    .help("Import private local historical receipts; no model call is made")
                    .accessibilityIdentifier("bridge.jev.importToolPages")
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
            }
            .menuStyle(.borderlessButton).fixedSize()
            .font(BridgeFont.secondaryMedium)
            .disabled(model.busy)
            .help("Import private local assessment files; no data is sent online")
        }
    }

    private var subtitle: String {
        guard inCurrentScope, let value = model.display, value.currentEvidence > 0 else { return "Model opinions about what each saved turn was for" }
        return "What models judged \(value.currentEvidence.formatted()) saved \(value.currentEvidence == 1 ? "turn" : "turns") to be about"
    }

    // MARK: Metadata assessments

    @ViewBuilder private var metadataSection: some View {
        if !inCurrentScope || (model.loading && model.display == nil) {
            Label("Preparing assessments for this selection…", systemImage: "hourglass")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
        } else if let value = model.display, value.currentEvidence > 0 {
            let parts = WorkSignalPart.parts(value)
            VStack(alignment: .leading, spacing: 12) {
                WorkSignalBar(parts: parts, total: value.currentEvidence)
                    .help(breakdown(value))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(parts) { part in
                        WorkSignalTile(part: part, total: value.currentEvidence)
                    }
                }
                HStack(spacing: 6) {
                    let flagged = value.flaggedRetry + value.flaggedCorrection + value.flaggedClarification + value.flaggedClaim
                    if flagged > 0 {
                        Tag(text: "\(flagged) to review", color: BridgeTheme.warning)
                            .help("Review candidates: \(value.flaggedRetry) retry · \(value.flaggedCorrection) correction · \(value.flaggedClarification) clarification · \(value.flaggedClaim) unsupported claim")
                    }
                    if value.differingLabels > 0 {
                        Tag(text: "\(value.differingLabels) labels differ").help("Models gave different labels, including one model saying unknown")
                    }
                    if value.singleJudge > 0 { Tag(text: "\(value.singleJudge) single-model").help("Assessed by only one model") }
                    if value.stale > 0 { Tag(text: "\(value.stale) stale").help("The saved turn changed after it was assessed; excluded") }
                    if value.unavailable > 0 { Tag(text: "\(value.unavailable) unavailable").help("The assessed turn is no longer in this snapshot; excluded") }
                    Spacer(minLength: 6)
                    Label("Model opinions, not verified outcomes", systemImage: "exclamationmark.bubble")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary).labelStyle(CompactLabelStyle())
                }
                DisclosureGroup("Inspect assessments") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(value.items.prefix(20))) { item in
                            Button {
                                inspect(item.sessionID, item.turnID)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(overview.sessions.first(where: { $0.id == item.sessionID })?.title ?? "Saved session")
                                        .font(BridgeFont.captionMedium).lineLimit(1)
                                    Text(item.modelOpinions.joined(separator: " · "))
                                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary).lineLimit(2)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(HoverRowButtonStyle())
                            .disabled(!model.canInspectMetadata(for: key))
                            .help(model.canInspectMetadata(for: key) ? "Inspect this saved turn and its evidence; model labels are unverified" : "Turn links are unavailable until this snapshot is checked successfully.")
                            .accessibilityIdentifier("bridge.jev.assessment.\(item.id)")
                        }
                        if value.items.count > 20 { Text("Showing 20 of \(value.items.count) current assessments") .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary) }
                    }.padding(.top, 8)
                }
                .font(BridgeFont.secondaryMedium)
                .accessibilityIdentifier("bridge.jev.details")
            }
        } else if let value = model.display, value.stale + value.unavailable > 0 {
            Label("No current assessments · \(value.stale) stale · \(value.unavailable) unavailable", systemImage: "clock.badge.exclamationmark")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
        } else if model.metadataReadFailed {
            Label("Assessment data is unavailable for this selection.", systemImage: "exclamationmark.circle")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
        } else {
            Label("No local assessments yet. Import an explicitly generated JEV assessment to see suggested work categories.", systemImage: "tray")
                .font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
        }
    }

    private func breakdown(_ value: JEVAssessmentDisplay) -> String {
        "\(value.insufficient) unclear · \(value.differingLabels) different model labels · \(value.disagreements) conflicting categories · \(value.incomparable) incomparable · \(value.singleJudge) single-model · \(value.stale) stale · \(value.unavailable) unavailable"
    }

    // MARK: Historical tool pages

    @ViewBuilder private var historicalSection: some View {
        let summary = model.historical?.summary
        DisclosureGroup(isExpanded: $historicalExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if !inCurrentScope || (model.loading && model.historical == nil) {
                    Text("Preparing historical captures…").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                } else if let summary {
                    if summary.captureCount > 0 {
                        HStack(alignment: .top, spacing: 20) {
                            historicalFigure(summary.nonzeroFlaggedCount.formatted(), "JEV: nonzero exit flags", icon: "flag", tint: summary.nonzeroFlaggedCount > 0 ? BridgeTheme.warning : nil)
                                .accessibilityLabel("\(summary.nonzeroFlaggedCount) captures flagged by JEV for a nonzero exit")
                                .help("Historical model opinions; a flag is not a verified failure")
                            historicalFigure("\(summary.partialCaptureCount.formatted()) / \(summary.captureCount.formatted())", "Partial tool pages", icon: "doc.badge.ellipsis", tint: nil)
                            InfoButton(title: "Historical JEV flags", text: "Model opinions about explicitly imported historical samples, not verified failures or a project-wide success rate. A capture is flagged when any saved opinion says a listed exit was nonzero; this includes contested opinions and can reflect an expected test. Different captures and rubrics stay separate. Partial tool pages count incomplete pages or truncated tool facts; artifact coverage may independently be partial. Uncertain opinions may omit relevant facts. No hidden reasoning or provider accounting is inferred.")
                            Spacer(minLength: 0)
                        }
                        Text("\(summary.nonzeroConflictCount) conflicting · \(summary.nonzeroUncertainCount) uncertain · \(summary.singleModelCount) single-model captures")
                            .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                    } else {
                        Text("No captured pages for this selection.").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                    }
                } else if model.toolReadFailed {
                    Text("Historical captures are unavailable for this selection.").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
                }
                if inCurrentScope && model.toolReadFailed {
                    CalloutBanner(tone: .warning, title: "Historical tool-page assessments could not be read",
                                  detail: "Previous results for this selection are shown if available; other activity is unchanged.", compact: true)
                }
                if inCurrentScope && !model.toolPages.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.toolPages.prefix(20))) { page in historicalPage(page) }
                        if model.toolPages.count > 20 { Text("Showing 20 of \(model.toolPages.count) captured pages · flagged first").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary) }
                    }
                    .accessibilityIdentifier("bridge.jev.toolPages")
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text("Historical tool pages").font(BridgeFont.secondaryMedium).foregroundStyle(BridgeTheme.textPrimary)
                if inCurrentScope, let summary, summary.captureCount > 0 {
                    Text("\(summary.captureCount.formatted()) captured").font(BridgeFont.caption).foregroundStyle(BridgeTheme.textTertiary)
                    if summary.nonzeroFlaggedCount > 0 {
                        Tag(text: "\(summary.nonzeroFlaggedCount) flagged", color: BridgeTheme.warning)
                    }
                }
                InfoButton(title: "Historical tool pages", text: "These are separate model opinions about a previously captured, potentially partial page. They are not refreshed when activity changes. 'No' refers only to listed facts, not the full session. Recorded goal status and artifacts do not prove success or delivery. Turn elapsed time is not GPU or provider compute time. Multiple opinions and disagreements are retained. No data is sent online when this view opens.")
            }
        }
    }

    private func historicalFigure(_ value: String, _ label: String, icon: String, tint: Color?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint ?? BridgeTheme.textTertiary).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(BridgeTheme.textPrimary)
                Text(label).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func historicalPage(_ page: JEVToolPageGroup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if page.exitFlagged {
                Label(page.exitOpinionsDiffer ? "Exit flagged by JEV · opinions differ" : "Exit flagged by JEV", systemImage: "flag.fill")
                    .font(BridgeFont.captionMedium).foregroundStyle(BridgeTheme.warning).labelStyle(CompactLabelStyle())
            }
            Text("Captured page · \(page.receipts.count) saved opinions\(page.receipts.contains(where: { $0.answers != page.first.answers }) ? " · opinions differ" : "")")
                .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary)
            ForEach(page.receipts) { receipt in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Imported model label: \(receipt.model) · \(receipt.assessedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "assessment time unknown")")
                        .font(BridgeFont.captionMedium)
                    Text("\(receipt.factCount) listed facts · \(receipt.pagePartial ? "partial page" : "captured page")\(receipt.toolFactsTruncated ? " · facts truncated" : "")\(receipt.artifactCountIsPartial ? " · artifact count partial" : "")")
                        .font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
                    Text(opinion(receipt.answers)).font(BridgeFont.micro).foregroundStyle(BridgeTheme.textSecondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.canInspectHistorical(for: key) {
                Text("Turn links are unavailable until this snapshot is checked successfully.").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            } else if hasTurn(page.first) {
                Button("Inspect saved turn") { inspect(page.first.sessionID, page.first.turnID) }
                    .font(BridgeFont.caption).help("Open the exact saved turn; this historical page may no longer match it")
            } else {
                Text("Original turn is unavailable or its identity is ambiguous.").font(BridgeFont.micro).foregroundStyle(BridgeTheme.textTertiary)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .bridgeWell()
    }
}

/// One slice of the assessed turns: an agreed work kind, or a turn the
/// models left unclear, disagreed on, or could not be compared. The slices
/// partition the current evidence, so the bar is a true part-to-whole.
struct WorkSignalPart: Identifiable, Equatable {
    var id: String
    var title: String
    var count: Int
    var symbol: String
    var color: Color
    var help: String

    static func parts(_ value: JEVAssessmentDisplay) -> [Self] {
        var parts = value.agreedKinds.filter { $0.value > 0 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { kind, count in
            let style = style(kind)
            return Self(id: kind, title: kind.capitalized, count: count, symbol: style.symbol, color: style.color,
                        help: "Models agreed this turn was \(kind)")
        }
        if value.insufficient > 0 {
            parts.append(Self(id: "unclear", title: "Unclear", count: value.insufficient, symbol: "questionmark.circle",
                              color: Color.white.opacity(0.2), help: "At least one model couldn't tell what the turn was for"))
        }
        if value.disagreements > 0 {
            parts.append(Self(id: "conflicting", title: "Models disagree", count: value.disagreements, symbol: "arrow.left.arrow.right",
                              color: Color.white.opacity(0.32), help: "Two models gave different specific labels"))
        }
        if value.incomparable > 0 {
            parts.append(Self(id: "incomparable", title: "Not comparable", count: value.incomparable, symbol: "equal.slash",
                              color: Color.white.opacity(0.12), help: "Assessments used different inputs, providers or rubric versions"))
        }
        return parts
    }

    /// Work kinds share the work-category colours and glyphs, so Research
    /// reads the same here as in the swimlanes and the tool mix.
    private static func style(_ kind: String) -> (symbol: String, color: Color) {
        let category = kind == "verification" ? "Tests" : kind.capitalized
        let symbol: String
        switch kind {
        case "debugging": symbol = "ladybug"
        case "planning": symbol = "list.bullet.clipboard"
        case "verification": symbol = "checkmark.seal"
        default: symbol = BridgeTheme.categorySymbol(category)
        }
        return (symbol, BridgeTheme.category(category))
    }
}

/// A thin 100% bar with a 2 pt surface gap between slices.
struct WorkSignalBar: View {
    var parts: [WorkSignalPart]
    var total: Int

    var body: some View {
        GeometryReader { proxy in
            let gaps = CGFloat(max(0, parts.count - 1)) * 2
            let available = max(0, proxy.size.width - gaps)
            HStack(spacing: 2) {
                ForEach(parts) { part in
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(part.color)
                        .frame(width: max(2, available * CGFloat(part.count) / CGFloat(max(1, total))))
                }
            }
        }
        .frame(height: 10)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assessed turns by work kind")
        .accessibilityValue(parts.map { "\($0.title) \($0.count)" }.joined(separator: ", "))
    }
}

/// A legend entry that is also the figure: glyph, count, kind and share.
struct WorkSignalTile: View {
    var part: WorkSignalPart
    var total: Int

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: part.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(part.color)
                .frame(width: 26, height: 26)
                .background(part.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(part.count.formatted()).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(BridgeTheme.textPrimary)
                    Text(share).font(BridgeFont.micro.monospacedDigit()).foregroundStyle(BridgeTheme.textTertiary)
                }
                Text(part.title).font(BridgeFont.caption).foregroundStyle(BridgeTheme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .help(part.help)
        .accessibilityElement(children: .combine)
    }

    private var share: String {
        let fraction = Double(part.count) / Double(max(1, total))
        if fraction > 0 && fraction < 0.005 { return "<1%" }
        return "\(Int((fraction * 100).rounded()))%"
    }
}
