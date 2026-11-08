import Foundation

/// How a model worked, per usage record: how much context each step sent and
/// how much it wrote. Each average divides a canonical subtotal by the records
/// that reported it, so a record without usage never dilutes the figure.
/// Presentation only: nothing here re-sums tokens.
public struct ModelWorkProfile: Equatable, Sendable {
    /// Known tokens per usage record that reported tokens.
    public var contextPerStep: Double?
    /// Output tokens per usage record that reported output.
    public var writtenPerStep: Double?
    /// Legacy turn records (several steps in one record) or partial coverage
    /// are mixed in, so the average is approximate rather than per step.
    public var approximate: Bool

    public init(_ row: ActivityModelAccounting.Row) {
        contextPerStep = Self.average(row.tokens, over: row.tokenReceipts)
        writtenPerStep = Self.average(row.output, over: row.outputReceipts)
        // A record without usage also counts as partial; only partial records
        // beyond those make a reported figure itself a lower bound.
        approximate = row.unmeasuredTurns > 0 || row.partialReceipts > max(0, row.usageRecords - row.tokenReceipts)
    }

    private static func average(_ total: Int?, over records: Int) -> Double? {
        guard let total, total >= 0, records > 0 else { return nil }
        let value = Double(total) / Double(records)
        return value.isFinite ? value : nil
    }
}
