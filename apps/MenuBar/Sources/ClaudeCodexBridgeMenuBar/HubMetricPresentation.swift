import CoreGraphics
import Foundation

enum SessionDurationHistogram {
    struct Result: Equatable {
        var counts: [Double?]
        var medianBucket: Int?
        var sampleCount: Int
    }

    static func build(_ durations: [Double]) -> Result {
        let valid = durations.filter { $0.isFinite && $0 >= 0 }.sorted()
        let edges: [Double] = [300, 900, 3_600, 14_400]
        func bucket(_ value: Double) -> Int { edges.firstIndex { value < $0 } ?? edges.count }
        guard !valid.isEmpty else { return Result(counts: Array(repeating: nil, count: 5), medianBucket: nil, sampleCount: 0) }
        var counts = Array(repeating: 0.0, count: 5)
        for value in valid { counts[bucket(value)] += 1 }
        // For an even sample, the numeric median may lie in an empty bin.
        // Emphasize the lower central observed session instead, never an
        // empty bar that falsely appears to contain a real session.
        return Result(counts: counts.map { Optional($0) }, medianBucket: bucket(valid[(valid.count - 1) / 2]), sampleCount: valid.count)
    }
}

enum MetricStripLayout {
    static let minimumCellWidth: CGFloat = 148
    static func columnCount(for width: CGFloat, itemCount: Int) -> Int {
        guard width.isFinite, width > 0, itemCount > 0 else { return 1 }
        return [6, 3, 2, 1].first { count in
            count <= itemCount && CGFloat(count) * minimumCellWidth + CGFloat(count - 1) <= width
        } ?? 1
    }
}

enum MiniBarsPresentation {
    enum Sample: Equatable {
        case measured(Double)
        case noRecords
        case unavailable
    }

    static func samples(_ values: [Double?], emptyIndices: Set<Int> = []) -> [Sample] {
        values.enumerated().map { index, value in
            if let value { return value.isFinite && value >= 0 ? .measured(value) : .unavailable }
            return emptyIndices.contains(index) ? .noRecords : .unavailable
        }
    }

    static func accessibilitySummary(_ values: [Double?], emptyIndices: Set<Int> = []) -> String {
        let values = samples(values, emptyIndices: emptyIndices)
        guard !values.isEmpty else { return "" }
        let measured = values.filter { if case .measured = $0 { return true }; return false }.count
        let empty = values.filter { $0 == .noRecords }.count
        let missing = values.filter { $0 == .unavailable }.count
        return "Mini chart: \(measured) measured \(measured == 1 ? "value" : "values"), \(empty) \(empty == 1 ? "interval" : "intervals") with no dated records, \(missing) \(missing == 1 ? "interval" : "intervals") with missing measurements. An interval without records is not a measured zero."
    }

    static func geometry(width: CGFloat, count: Int) -> (barWidth: CGFloat, gap: CGFloat) {
        guard width.isFinite, width > 0, count > 0 else { return (0, 0) }
        let slot = width / CGFloat(count)
        let preferred: CGFloat = count > 20 ? 1.5 : (count > 10 ? 2 : 3)
        // Wide slots keep thin bars: a quarter of each slot is gap, so a week
        // across a wide card reads as seven bars rather than touching blocks.
        let wanted = slot >= 12 ? max(preferred, slot * 0.25) : preferred
        let gap = min(wanted, max(0, slot - 0.5))
        return (max(0, (width - gap * CGFloat(count - 1)) / CGFloat(count)), gap)
    }
}
