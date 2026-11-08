import AppKit
import BridgeCore
import SwiftUI

/// Presentation never upgrades an empty, partial or inconsistent ledger to
/// verified just because a compatibility flag is true.
enum ProviderProofPresentation {
    enum State: Equatable { case empty, unchecked, invalid, identityMismatch, partial, threeProviders, twoProviders, participationIncomplete }

    static func hasEffortMismatch(_ identity: ProviderIdentity) -> Bool {
        guard let requested = meaningful(identity.requestedEffort),
              let resolved = meaningful(identity.resolvedEffort) else { return false }
        return requested.caseInsensitiveCompare(resolved) != .orderedSame
    }

    static func hasIdentityMismatch(_ identity: ProviderIdentity) -> Bool {
        identity.hasMismatch || hasEffortMismatch(identity)
    }

    static func state(summary: TraceSummary?, records: [TraceRecord], snapshotIsConsistent: Bool = true) -> State {
        guard !records.isEmpty else { return .empty }
        guard let summary, snapshotIsConsistent else { return .unchecked }
        guard summary.traceVerified else { return .invalid }
        if records.contains(where: { hasIdentityMismatch($0.identity) }) { return .identityMismatch }
        let missingDetails = records.contains { record in
            guard [.claude, .codex, .grok].contains(record.provider), record.outcome == "success" else { return false }
            return meaningful(record.identity.resolvedModel) == nil
                || (meaningful(record.identity.requestedEffort) != nil && meaningful(record.identity.resolvedEffort) == nil)
                || record.usage.total == nil || (record.usage.total ?? -1) < 0
                || record.usage.provenance == .estimated || record.usage.provenance == .unavailable
        }
        guard summary.completeness == .complete,
              records.allSatisfy({ $0.completeness == .complete }), !missingDetails else { return .partial }
        if summary.threeProviderVerified { return .threeProviders }
        if summary.dualProviderVerified { return .twoProviders }
        return .participationIncomplete
    }

    static func headline(_ state: State) -> String {
        switch state {
        case .empty: return "No requests recorded yet"
        case .unchecked: return "Verification needs a refresh"
        case .invalid: return "Record integrity needs attention"
        case .identityMismatch: return "Model settings need attention"
        case .partial: return "Some verification details are missing"
        case .threeProviders: return "All three providers took part"
        case .twoProviders: return "Claude and Codex took part"
        case .participationIncomplete: return "Provider participation is incomplete"
        }
    }

    static func meaningful(_ value: String?) -> String? {
        let result = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return result?.isEmpty == false ? result : nil
    }
}

@MainActor
final class ProviderProofModel: ObservableObject {
    @Published var records: [TraceRecord] = []
    @Published var summary: TraceSummary?
    @Published var errorMessage: String?
    var client: BridgeAPIClient?
    @Published private(set) var isRefreshing = false
    @Published private(set) var snapshotIsConsistent = true
    private var reloadTask: Task<Void, Never>?
    private var reloadID: UUID?

    func reload() {
        guard let client else { errorMessage = "The local runtime is connecting. Try again when it is ready."; return }
        guard reloadTask == nil else { return }
        let id = UUID(); reloadID = id; isRefreshing = true
        reloadTask = Task {
            defer { if reloadID == id { reloadTask = nil; isRefreshing = false } }
            do {
                async let records = client.trace(limit: 2_000)
                async let summary = client.traceSummary()
                let (newRecords, newSummary) = try await (records, summary)
                guard !Task.isCancelled, reloadID == id else { return }
                self.records = newRecords
                self.summary = newSummary
                snapshotIsConsistent = newRecords.count == min(max(0, newSummary.records), 2_000)
                    && (newRecords.isEmpty || newRecords.last?.bridgeSessionID == newSummary.bridgeSessionID)
                errorMessage = nil
            } catch {
                guard !Task.isCancelled, reloadID == id else { return }
                errorMessage = BridgeLogPresentation.text(error.localizedDescription)
            }
        }
    }

    func stopReloading() { reloadID = nil; reloadTask?.cancel(); reloadTask = nil; isRefreshing = false }

    func export() {
        guard let client else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bridge-trace.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let data = try await client.traceExport()
                try data.write(to: url, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
            } catch {
                errorMessage = BridgeLogPresentation.text(error.localizedDescription)
            }
        }
    }

    func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
final class ProviderProofController: NSObject {
    static let shared = ProviderProofController()
    let model = ProviderProofModel()
    var openInReports: (@MainActor () -> Void)?

    func show(client: BridgeAPIClient) {
        model.client = client
        openInReports?()
    }
}

@MainActor
struct ProviderProofPage: View {
    var client: BridgeAPIClient?
    var clientID: UUID?
    @ObservedObject private var model = ProviderProofController.shared.model
    var body: some View {
        ProviderProofView(model: model)
            .task(id: clientID) { model.stopReloading(); model.client = client; model.reload() }
            .onDisappear { model.stopReloading() }
    }
}

private struct ProviderProofView: View {
    @ObservedObject var model: ProviderProofModel
    @State private var expandedReceipts: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.errorMessage, model.records.isEmpty {
                emptyState(
                    title: "Records couldn't be loaded",
                    icon: "exclamationmark.triangle",
                    detail: error
                )
            } else if model.records.isEmpty && model.isRefreshing {
                ProgressView("Loading verification records…").frame(maxHeight: .infinity)
            } else if model.records.isEmpty {
                HubEmptyState(
                    icon: "doc.text.magnifyingglass",
                    title: "Nothing to verify yet",
                    message: "When Agent Hub runs a request through Claude, Codex or Grok, it records which provider and model actually answered, how long it took and what it used. Those records appear here and can be exported as proof."
                )
                .frame(maxHeight: .infinity)
            } else {
                if let error = model.errorMessage {
                    Label("Couldn't refresh. Previously loaded records are shown. \(error)", systemImage: "exclamationmark.triangle")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !model.snapshotIsConsistent {
                    Label("New records arrived during this refresh. Refresh again before relying on the summary.", systemImage: "arrow.clockwise.circle")
                        .font(BridgeFont.caption).foregroundStyle(BridgeTheme.warning)
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                List(model.records.reversed()) { record in
                    TraceReceiptRow(record: record, copy: model.copy, expanded: Binding(
                        get: { expandedReceipts.contains(record.id) },
                        set: { value in if value { expandedReceipts.insert(record.id) } else { expandedReceipts.remove(record.id) } }
                    ))
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BridgeTheme.ink)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bridge.page.provider-proof")
        .onChange(of: model.records.map(\.id)) { ids in expandedReceipts.formIntersection(Set(ids)) }
        .onReceive(NotificationCenter.default.publisher(for: AcceptanceProbe.command)) { note in
            AcceptanceProbe.handleSafe(note, scope: "provider-proof", state: {
                let present = Set(model.records.map(\.id))
                var state = AcceptanceProbe.serviceFields(loading: model.isRefreshing, ready: model.summary != nil, hasData: !model.records.isEmpty,
                    error: (model.client != nil && model.errorMessage != nil) || !model.snapshotIsConsistent,
                    unsupported: RefreshAcceptance.isReplayMode && model.client == nil, itemCount: model.records.count)
                state["expanded"] = expandedReceipts.intersection(present).sorted().joined(separator: ",")
                return state
            }, exercise: {
                guard !model.isRefreshing, model.summary != nil, model.errorMessage == nil, model.snapshotIsConsistent, let record = model.records.last else { return false }
                expandedReceipts.insert(record.id)
                return true
            })
        }
    }

    private func emptyState(title: String, icon: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 12) { status; Spacer(minLength: 12); actions }
          VStack(alignment: .leading, spacing: 12) { status; HStack { Spacer(); actions } }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }

    private var state: ProviderProofPresentation.State {
        ProviderProofPresentation.state(summary: model.summary, records: model.records, snapshotIsConsistent: model.snapshotIsConsistent && model.errorMessage == nil)
    }

    private var status: some View {
        HStack(spacing: 12) {
            let verified = state == .threeProviders || state == .twoProviders
            Image(systemName: verified ? "checkmark.seal.fill" : (state == .empty ? "doc.text.magnifyingglass" : "questionmark.circle"))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(verified ? BridgeTheme.success : BridgeTheme.textTertiary)
                .frame(width: 34, height: 34)
                .background((verified ? BridgeTheme.success : Color.white).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(ProviderProofPresentation.headline(state))
                    .font(BridgeFont.heading)
                Text(summaryText)
                    .font(BridgeFont.caption)
                    .foregroundStyle(BridgeTheme.textSecondary)
            }
        }
        .help("Verification checks recorded provider participation and measurements. It does not independently guarantee the quality of the work.")
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if model.summary?.traceVerified == true, !model.records.isEmpty, model.snapshotIsConsistent, model.errorMessage == nil {
                Label("Records unaltered", systemImage: "lock.shield")
                    .font(BridgeFont.caption)
                    .foregroundStyle(BridgeTheme.success)
                    .help("Each record is chained to the one before it, so any later edit would be detected.")
            }
            Button { model.export() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .buttonStyle(BridgeSecondaryButtonStyle(compact: true))
                .disabled(model.client == nil || model.records.isEmpty || model.isRefreshing)
                .help("Save the records, with secrets removed")
                .accessibilityHint("Saves the records with secrets removed")
            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(BridgeIconButtonStyle(size: 26))
            .disabled(model.isRefreshing)
            .accessibilityLabel("Refresh verification")
        }
    }

    private var summaryText: String {
        guard let summary = model.summary else { return "Loading…" }
        let tokens = summary.totalTokens.flatMap { $0 >= 0 ? (summary.completeness == .complete ? "" : "at least ") + ActivityFormat.compact($0) + " recorded tokens" : nil } ?? "tokens not reported"
        let count = summary.records > model.records.count
            ? "Newest \(model.records.count.formatted()) of \(summary.records.formatted()) records"
            : "\(summary.records.formatted()) \(summary.records == 1 ? "record" : "records")"
        return "Bridge-managed trace scope only · \(count) · \(tokens) · \(summary.toolCalls.formatted()) tool uses"
    }
}

private struct TraceReceiptRow: View {
    let record: TraceRecord
    let copy: @MainActor (String) -> Void
    @Binding var expanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                detail("Asked for", identity(record.identity.requestedModel, record.identity.requestedEffort))
                detail("Provider reported", identity(record.identity.resolvedModel, record.identity.resolvedEffort))
                if ProviderProofPresentation.hasIdentityMismatch(record.identity) {
                    detail("Settings differ", "The reported model or effort differs from the request. Review both values above.")
                }
                detail("Session ID", record.nativeSessionID ?? "Not recorded")
                detail("Tokens", tokenText)
                detail("Token source", provenanceText)
                detail("Time taken", durationText)
                detail("Details available", record.completeness == .complete ? "Complete" : (record.completeness == .legacy ? "Imported history · some details missing" : "Partial · some details missing"))
                if !record.warnings.isEmpty {
                    detail("Warnings", record.warnings.joined(separator: " · "))
                }
            }
            .font(.caption)
            .padding(.vertical, 8)

            ForEach(record.tools) { tool in
                HStack {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(BridgeLogPresentation.text(tool.name)).font(.caption.monospaced())
                    Spacer()
                    Text(BridgeLogPresentation.text(tool.status)).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 8)
            }
            if let id = record.nativeSessionID,
               record.provider == .claude || record.provider == .codex
            {
                Button {
                    copy(id)
                    openProviderApplication()
                } label: {
                    Label(
                        "Open \(record.provider.rawValue.capitalized) and copy session ID",
                        systemImage: "arrow.up.forward.app"
                    )
                }
                .buttonStyle(.link)
                .help("The provider app opens normally; the searchable native ID is copied.")
            }
        } label: {
            HStack(spacing: 10) {
                AgentAvatar(name: record.provider.rawValue.capitalized, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.provider.rawValue.capitalized)
                        .font(.subheadline.weight(.semibold))
                    Text(record.identity.resolvedModel ?? record.identity.requestedModel ?? "Model unavailable")
                        .font(.caption.monospaced())
                        .foregroundStyle(ProviderProofPresentation.hasIdentityMismatch(record.identity) ? BridgeTheme.warning : BridgeTheme.textSecondary)
                }
                Spacer()
                Text(outcomeTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(outcomeColor)
                Text(record.timestamp, format: .dateTime.day().month(.abbreviated).hour().minute())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contextMenu {
                if let id = record.nativeSessionID {
                    Button("Copy session ID") { copy(id) }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(BridgeLogPresentation.text(value)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func identity(_ model: String?, _ effort: String?) -> String {
        [model, effort.map { "\($0) effort" }].compactMap { $0 }.joined(separator: " · ")
            .nonEmpty ?? "Unavailable"
    }

    private var tokenText: String {
        let usage = record.usage
        return [
            usage.input.map { "input \($0.formatted())" },
            usage.output.map { "output \($0.formatted())" },
            usage.cachedInput.map { "reused input \($0.formatted())" },
            usage.cacheWriteInput.map { "saved to cache \($0.formatted())" },
            usage.reasoning.map { "reasoning subset \($0.formatted())" },
            usage.total.map { "total \($0.formatted())" },
        ].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Unavailable"
    }

    private var provenanceText: String {
        switch record.usage.provenance {
        case .providerReported: return "Reported by the provider"
        case .derived: return "Calculated from reported measurements"
        case .estimated: return "Estimate, not a provider measurement"
        case .unavailable: return "Not reported"
        }
    }

    private var durationText: String {
        record.durationMilliseconds.flatMap { $0 >= 0 ? ActivityFormat.duration(Double($0) / 1_000) : nil } ?? "Not recorded"
    }

    private var outcomeTitle: String {
        switch record.outcome.lowercased() {
        case "success": return "Completed"
        case "historical": return "Imported"
        case "cancelled", "canceled": return "Stopped"
        case "failure", "failed", "error": return "Failed"
        default: return ProviderProofPresentation.meaningful(record.outcome)?.capitalized ?? "Not reported"
        }
    }

    private var outcomeColor: Color {
        switch record.outcome.lowercased() {
        case "success": return BridgeTheme.success
        case "failure", "failed", "error": return BridgeTheme.danger
        case "paused", "cancelled", "canceled": return BridgeTheme.warning
        default: return BridgeTheme.textSecondary
        }
    }

    private func openProviderApplication() {
        let bundleID = record.provider == .claude
            ? "com.anthropic.claudefordesktop"
            : "com.openai.codex"
        guard let url = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleID
        ) else { return }
        NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
