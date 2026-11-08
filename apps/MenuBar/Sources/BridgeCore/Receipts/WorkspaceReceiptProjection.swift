import Foundation

/// Writes the canonical accounting receipts as portable workspace receipts.
/// One accounting receipt becomes one workspace receipt with the same usage,
/// time basis and inclusion, so folding the projection with
/// `WorkspaceReceiptLedger` reproduces the accounting totals exactly.
public enum WorkspaceReceiptProjection {
    public static let adapter = WorkspaceReceipt.Producer(adapter: "agent-hub.accounting", adapterVersion: "1")

    public static func receipts(from report: ActivityAccounting.Report) throws -> [WorkspaceReceipt] {
        let native = Dictionary(report.nativeObservations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try report.receipts.map { receipt in
            let unit: WorkspaceReceipt.Unit = receipt.kind == .modelStep ? .modelStep : .conversationTurn
            // The strongest time the receipt actually carries.
            let hasInterval = receipt.intervalStart != nil || receipt.intervalEnd != nil
            let basis: WorkspaceReceipt.Time.Basis
            switch receipt.timeBasis {
            case .providerEvent where receipt.timestamp != nil: basis = .providerEvent
            case .providerEvent, .nativeInterval: basis = hasInterval ? .nativeInterval : .unplaced
            case .unplaced: basis = .unplaced
            }
            let usage = receipt.usage
            func quantity(_ value: Int?) -> TokenQuantity? { value.flatMap(TokenQuantity.init) }
            let provenance: WorkspaceReceipt.Provenance
            switch usage.provenance {
            case .providerReported: provenance = .providerReported
            case .derived: provenance = .derived
            case .estimated: provenance = .estimated
            case .unavailable: provenance = .unavailable
            }
            let negative = [usage.input, usage.output, usage.cachedInput, usage.cacheWriteInput, usage.reasoning, usage.total].contains { ($0 ?? 0) < 0 }
            let completeness: WorkspaceReceipt.Completeness = negative || receipt.usageIsPartial == true || receipt.countIsPartial ? .partial
                : (receipt.usageIsPartial == false ? .complete : .unknown)
            // Turn counters belong to the turn record, never to each model step.
            let observation = unit == .conversationTurn ? native[receipt.provider.rawValue + ":" + receipt.nativeTurnID] : nil
            let aggregates = observation.map { WorkspaceReceipt.Aggregates(toolCalls: $0.toolCalls, submittedPrompts: $0.submittedPrompts, confirmedHumanPrompts: $0.confirmedHumanPrompts) }
            let time = WorkspaceReceipt.Time(basis: basis, at: basis == .providerEvent ? receipt.timestamp : nil,
                                             start: receipt.intervalStart, end: receipt.intervalEnd)
            let value = WorkspaceReceipt(
                eventID: "agent-hub:\(receipt.provider.rawValue):\(receipt.id)", observedAt: receipt.observedAt, producer: adapter,
                provider: receipt.provider.rawValue, sessionID: receipt.sessionID, nativeTurnID: receipt.nativeTurnID, unit: unit,
                time: time, model: receipt.model, effort: receipt.effort,
                usage: .init(input: negative ? nil : quantity(usage.input), cachedInput: negative ? nil : quantity(usage.cachedInput),
                             cacheWriteInput: negative ? nil : quantity(usage.cacheWriteInput), output: negative ? nil : quantity(usage.output),
                             reasoning: negative ? nil : quantity(usage.reasoning), total: negative ? nil : quantity(usage.total),
                             inputIncludesCachedInput: receipt.provider == .codex ? true : (receipt.provider == .claude ? false : nil),
                             provenance: provenance, completeness: completeness),
                aggregates: aggregates, projectPath: receipt.projectPath, includedInTotals: receipt.includedInTotals && basis != .unplaced,
                evidence: String(receipt.evidence.prefix(128)))
            return try value.sealed()
        }
    }
}
