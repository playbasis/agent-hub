import Foundation

extension ActivityAccounting.Report {
    /// Monday-first provider-event heatmap, using the canonical scoped step
    /// receipts. No native-turn completion date is substituted for a step.
    public func weekdayHourModelSteps(timeZone: TimeZone = ActivityAnalytics.reportingTimeZone) -> [[Int]]? {
        guard isValid else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for receipt in receipts where receipt.countsAsModelStep {
            guard let at = receipt.timestamp, at.timeIntervalSinceReferenceDate.isFinite else { continue }
            let day = (calendar.component(.weekday, from: at) + 5) % 7
            let hour = calendar.component(.hour, from: at)
            let next = grid[day][hour].addingReportingOverflow(1)
            guard !next.overflow else { return nil }
            grid[day][hour] = next.partialValue
        }
        return grid
    }

    public func overnightModelStepShare(timeZone: TimeZone = ActivityAnalytics.reportingTimeZone) -> Double? {
        guard isValid, totals.observedModelSteps > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let count = receipts.filter { receipt in
            receipt.countsAsModelStep && receipt.timestamp.map { calendar.component(.hour, from: $0) < 7 } == true
        }.count
        return Double(count) / Double(totals.observedModelSteps)
    }
}
