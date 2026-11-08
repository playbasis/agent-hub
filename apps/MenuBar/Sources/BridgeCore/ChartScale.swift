import Foundation

/// A zero-based value axis that hugs its data: the top is the smallest
/// 1, 2, 2.5 or 5 × 10ⁿ step multiple above the peak, with three to seven
/// intervals, so the tallest bar fills most of the plot and the top keeps a
/// labelled grid line.
public struct ChartScale: Equatable, Sendable {
    public var upperBound: Double
    public var ticks: [Double]

    /// Room above the tallest bar so it never touches the top line.
    static let headroom = 1.02

    public init(peak: Double) {
        guard peak.isFinite, peak > 0 else {
            upperBound = 1; ticks = [0, 1]; return
        }
        let target = peak * Self.headroom
        guard target.isFinite, target < 1e300 else {
            upperBound = .greatestFiniteMagnitude
            ticks = (0 ... 5).map { Double.greatestFiniteMagnitude * (Double($0) / 5) }
            return
        }
        let base = pow(10, floor(log10(target / 7)))
        var best: (upper: Double, step: Double, count: Int)?
        for power in [base, base * 10] {
            for multiplier in [1, 2, 2.5, 5] {
                let step = power * multiplier
                let count = Int(ceil(target / step))
                guard (3 ... 7).contains(count) else { continue }
                let upper = Double(count) * step
                if best == nil || upper < best!.upper - step * 1e-9 { best = (upper, step, count) }
            }
        }
        // `target / 7` always yields a step inside 3…7 intervals; the
        // fallback only guards against rounding at the edges.
        let chosen = best ?? (target, target / 4, 4)
        upperBound = chosen.upper
        ticks = (0 ... chosen.count).map { Double($0) * chosen.step }
    }

    /// Peak of stacked bars: the largest per-bucket sum.
    public init<Bucket: Hashable>(stacked values: [(bucket: Bucket, value: Int)]) {
        var sums: [Bucket: Double] = [:]
        for item in values where item.value > 0 { sums[item.bucket, default: 0] += Double(item.value) }
        self.init(peak: sums.values.max() ?? 0)
    }
}
